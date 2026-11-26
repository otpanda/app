package org.otpanda.totp

import java.security.SecureRandom
import java.util.Base64

// Dedicated per-owner seed-sync enrollment key and its persisted deny-first erase state machine (seed-sync design v4, section 1, 2 and reviewer
// correction 1). INACTIVE: not wired to the app, no network, no API route, synthetic keys only. It never touches the shared durable device key.
//
// One enrollment = one P-256 signing key under its own random vault alias, recorded per owner in a durable document. Erase is fail closed and ordered:
//   a. commit, in ONE atomic write: the key moved from `active` to a deny record AND an `owed` purge (or opt-out) obligation. Every use of a key reads the
//      durable document, so a denied key is never used again, in this process or after a restart.
//      If this commit fails, an in-memory erase INTENT for the owner is kept for the life of the process: sign and enroll refuse (ERASE_INCOMPLETE) until a later
//      erase or [retryPending] commits it. The alias is also deleted best effort and the seeds are still purged, then ERASE_INCOMPLETE is thrown.
//      WIRING REQUIREMENT (unproven here): the caller persists its own sign-out/disable/switch intent and re-runs erase or [retryPending] until it succeeds,
//      because a process death in that window (commit failed and delete failed) leaves the durable document saying `active`.
//   b. purge the owner's seeds (sign-out, owner switch, definitive remote code) or opt the owner out (disable) through NativeSeedCustodyCore. `owed` is cleared only
//      after the call reports the seeds purged; any failure (custody error, RuntimeException) keeps `owed` durable. Each new erase captures the real native epoch; retries replay that durable capture without advancing again.
//   c. ALWAYS (try/finally, whatever step b threw) delete the vault alias, then READ BACK (fresh containsAlias) that it is absent. A delete that throws but
//      leaves the alias absent counts as deleted; deleting an absent alias is not an error. Only then is the deny record cleared. A still-present alias keeps
//      the deny record; [retryPending] repeats this at app start, foreground and unlock.
// A new enrollment always uses a fresh random alias and key id. It never reuses a name. An unresolved deny record of an earlier key does not block it, but an
// owed purge, an erase intent, or 15 unresolved deny records do (ERASE_INCOMPLETE). Documents hold at most 16 deny records.
// Corrupt documents: the owner stays unusable, seeds are still purged on erase, nothing is deleted blindly (no owner or alias is grounded), and
// [resetUnreadableState] is the explicit, caller-driven recovery (it records an owed purge, then [sweepOrphans] removes the unreferenced alias).
// Keystore deletion is best effort and unproven on real devices; the deny record is what keeps a lingering alias unusable.
// No seed is handled here. The signature format and the signed message bytes are NOT defined here: they come from the API contract.

enum class SyncKeyError { NOT_ENROLLED, MISSING_KEY, UNAVAILABLE, METADATA_UNAVAILABLE, INVALID_INPUT, ERASE_INCOMPLETE }

/** Carries only the error kind: never a key, alias, message or platform text. */
class SyncKeyFailure(val error: SyncKeyError) : Exception(error.name)

/** Signing-key vault. No private-key read exists. Real implementation (Android Keystore EC P-256) is not part of this change. */
interface SyncKeyVault {
    fun containsAlias(alias: String): Boolean
    fun aliases(): Set<String>
    /** Creates a non-exportable P-256 signing key under [alias] and returns its public key (X9.62 uncompressed point). Throws VaultException. */
    fun generate(alias: String): ByteArray
    /** Signs [message] with the alias's key. Throws VaultException (LOCKED, INVALIDATED, UNAVAILABLE). */
    fun sign(alias: String, message: ByteArray): ByteArray
    fun delete(alias: String)
}

/** Durable non-secret enrollment state, one document per owner key. Same contract as [OwnerStateStore] but a SEPARATE store instance (its own directory). */
interface SyncStateStore {
    fun read(key: String): String?
    /** Atomic replace. A failed write must leave the previous document intact. */
    fun write(key: String, text: String)
    /** Every stored key. An unlistable store must throw, never return an empty set. */
    fun keys(): Set<String>
}

enum class EraseTrigger { SIGN_OUT, DISABLE, OWNER_SWITCH, REMOTE_KEY_REVOKED, REMOTE_DEVICE_REVOKED, REMOTE_SESSION_REVOKED, GENERATION_CHANGED }

/** [seedsPurged] false means a physical seed delete or the custody step is still pending. [keyDeleted] false means the deny record is retained for retry. */
data class EraseOutcome(val seedsPurged: Boolean, val keyDeleted: Boolean, val epoch: Long)

/** [keyDeletesPending] deny records still unresolved; [purgesOwed] owners whose seed purge or opt-out is still owed; [unreadableOwners] documents that could not be used
 * (left untouched). Each owner is handled independently: one failure never stops the others. */
data class RetryResult(val keyDeletesPending: Int, val purgesOwed: Int, val unreadableOwners: Int) {
    val clean: Boolean get() = keyDeletesPending == 0 && purgesOwed == 0 && unreadableOwners == 0
}

/** [generation] and [installId] are the values recorded durably at enrollment; every later proof takes them from the record, never from a caller. */
data class Enrollment(val keyId: String, val publicKey: ByteArray, val generation: Long, val installId: String)

/** What a signing step may rely on, all read under the core lock from native state: the active key's id, its enrollment generation and install id, and the
 * owner's REAL native epoch (read lazily from custody; a failed read refuses the proof that needs it). */
class SignContext internal constructor(val keyId: String, val generation: Long, val installId: String, private val epochRead: () -> Long) {
    val epoch: Long get() = epochRead()
}

enum class RemoteCodeAction { PURGE, SUSPEND, IGNORE }

/** Design v4 section 4. Only these exact definitive codes purge; session or idle expiry suspends and keeps seeds; anything else (bare 401/403, captive portal,
 * wrong schema, 5xx, timeout, skew, null, unknown) changes nothing. The caller must have verified the signed schema before passing a code. */
fun classifyRemoteCode(code: String?): RemoteCodeAction = when (code) {
    "seed-sync-key-revoked", "device-revoked", "session-revoked", "security-generation-changed" -> RemoteCodeAction.PURGE
    "session-expired", "idle-expired" -> RemoteCodeAction.SUSPEND
    else -> RemoteCodeAction.IGNORE
}
fun eraseTriggerFor(code: String?): EraseTrigger? = when (code) {
    "seed-sync-key-revoked" -> EraseTrigger.REMOTE_KEY_REVOKED
    "device-revoked" -> EraseTrigger.REMOTE_DEVICE_REVOKED
    "session-revoked" -> EraseTrigger.REMOTE_SESSION_REVOKED
    "security-generation-changed" -> EraseTrigger.GENERATION_CHANGED
    else -> null
}

private const val SYNC_HEADER = "otpanda-seedsync-state-v1"
private const val SYNC_ALIAS_PREFIX = "otpanda.seedsync.v1."
private val SYNC_ALIAS = Regex("otpanda\\.seedsync\\.v1\\.[0-9a-f]{32}")
private val SYNC_KEY_ID = Regex("[0-9a-f]{32}")
private val SYNC_INSTALL = Regex("[A-Za-z0-9_-]{22,64}")


private const val MAX_DENY = 16
internal enum class Owed { NONE, PURGE, DISABLE }

internal data class SyncKeyRef(val keyId: String, val alias: String)

internal class SyncState(val owner: String) {
    var active: SyncKeyRef? = null
    var activeGeneration = 0L
    var activeInstall = ""
    var owed = Owed.NONE
    var owedEpoch: Long? = null
    val deny = ArrayList<SyncKeyRef>()

    fun encode(): String = buildString {
        append(SYNC_HEADER).append('\n').append("owner ").append(Base64.getUrlEncoder().withoutPadding().encodeToString(owner.toByteArray(Charsets.UTF_8))).append('\n')
        append(active?.let { "active ${it.keyId} ${it.alias} $activeGeneration $activeInstall" } ?: "active none").append('\n')
        append("owed ").append(owed.name.lowercase()).append('\n')
        append("epoch ").append(owedEpoch?.toString() ?: "none").append('\n')
        for (d in deny.sortedWith(compareBy({ it.alias }, { it.keyId }))) append("deny ${d.keyId} ${d.alias}\n")
        append("end\n")
    }

    companion object {
        /** Strict: exact grammar, canonical re-encoding, owner must match. Anything else is unusable (callers fail closed). */
        fun decode(text: String, expectedOwner: String): SyncState {
            require(text.length <= 65_536)
            val lines = text.split('\n')
            require(lines.size >= 7 && lines.last().isEmpty() && lines[lines.size - 2] == "end" && lines[0] == SYNC_HEADER && lines[1].startsWith("owner "))
            val owner = String(Base64.getUrlDecoder().decode(lines[1].removePrefix("owner ")), Charsets.UTF_8)
            require(owner == expectedOwner && validCustodyId(owner))
            val s = SyncState(owner)
            if (lines[2] != "active none") {
                val p = lines[2].split(' ')
                require(p.size == 5 && p[0] == "active" && p[1].matches(SYNC_KEY_ID) && p[2].matches(SYNC_ALIAS) && p[3].matches(Regex("0|[1-9][0-9]{0,15}")) && p[4].matches(SYNC_INSTALL))
                s.active = SyncKeyRef(p[1], p[2]); s.activeGeneration = p[3].toLong(); s.activeInstall = p[4]
            }
            require(lines[3].startsWith("owed ")); s.owed = Owed.values().firstOrNull { it.name.lowercase() == lines[3].removePrefix("owed ") } ?: throw IllegalArgumentException()
            require(lines[4].startsWith("epoch "))
            s.owedEpoch = lines[4].removePrefix("epoch ").let { if (it == "none") null else it.toLong().also { n -> require(n >= 0 && n < Long.MAX_VALUE) } }
            require(s.owed != Owed.NONE || s.owedEpoch == null)
            for (i in 5 until lines.size - 2) {
                val p = lines[i].split(' '); require(p.size == 3 && p[0] == "deny" && p[1].matches(SYNC_KEY_ID) && p[2].matches(SYNC_ALIAS))
                s.deny.add(SyncKeyRef(p[1], p[2]))
            }
            require(s.deny.size <= MAX_DENY)
            require(s.deny.map { it.alias }.toSet().size == s.deny.size && s.active?.let { a -> s.deny.none { it.alias == a.alias } } != false)
            require(s.encode() == text) { "not canonical" }
            return s
        }
    }
}

class SeedSyncKeyCore(
    private val vault: SyncKeyVault,
    private val store: SyncStateStore,
    private val custody: NativeSeedCustodyCore,
    private val randomHex: () -> String = { ByteArray(16).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) } },
) {
    private val lock = Any()
    /** Process-lifetime erase intents whose durable commit has not succeeded (owner to trigger). While present, sign and enroll refuse. */
    private val intents = HashMap<String, EraseTrigger>()
    private fun fail(e: SyncKeyError): Nothing = throw SyncKeyFailure(e)

    private fun load(owner: String): SyncState = try {
        store.read(ownerKey(owner))?.let { SyncState.decode(it, owner) } ?: SyncState(owner)
    } catch (_: Exception) { fail(SyncKeyError.METADATA_UNAVAILABLE) }
    private fun save(state: SyncState) {
        try { store.write(ownerKey(state.owner), state.encode()) } catch (_: Exception) { fail(SyncKeyError.METADATA_UNAVAILABLE) }
    }
    private fun checkOwner(owner: String) { if (!validCustodyId(owner)) fail(SyncKeyError.INVALID_INPUT) }

    /** True when a durable enrollment exists and no erase is in flight. Never creates anything. */
    fun enrolled(owner: String): Boolean = synchronized(lock) { checkOwner(owner); owner !in intents && load(owner).active != null }

    /** Unresolved deny records (keys whose deletion is not confirmed). No aliases are exposed. */
    fun pendingKeyDeletes(owner: String): Int = synchronized(lock) { checkOwner(owner); load(owner).deny.size }

    /** True while a seed purge or opt-out is still owed for the owner (durable). */
    fun purgeOwed(owner: String): Boolean = synchronized(lock) { checkOwner(owner); load(owner).owed != Owed.NONE }

    /** Creates a fresh enrollment key. Refused (ERASE_INCOMPLETE) while an erase is unresolved: an owed purge, an uncommitted erase intent, or 15 deny records.
     * An existing enrollment is moved to a deny record in the same write that records the new key, then deleted and confirmed absent. A crash between key
     * creation and the write leaves only an orphan alias for [sweepOrphans]. */
    fun enroll(owner: String, installId: String, generation: Long): Enrollment = synchronized(lock) {
        checkOwner(owner)
        if (!SYNC_INSTALL.matches(installId) || generation < 0 || generation > 9_007_199_254_740_991L) fail(SyncKeyError.INVALID_INPUT)
        val state = load(owner)
        if (owner in intents || state.owed != Owed.NONE || state.deny.size >= MAX_DENY - 1) fail(SyncKeyError.ERASE_INCOMPLETE)
        val ref = SyncKeyRef(randomHex(), SYNC_ALIAS_PREFIX + randomHex())
        if (!ref.keyId.matches(SYNC_KEY_ID) || !ref.alias.matches(SYNC_ALIAS) || state.deny.any { it.alias == ref.alias } || state.active?.alias == ref.alias) fail(SyncKeyError.INVALID_INPUT)
        val pub = try { vault.generate(ref.alias) } catch (_: Exception) { fail(SyncKeyError.UNAVAILABLE) }
        val old = state.active
        if (old != null) state.deny.add(old)
        state.active = ref; state.activeGeneration = generation; state.activeInstall = installId
        try { save(state) } catch (e: SyncKeyFailure) { try { vault.delete(ref.alias) } catch (_: Exception) {}; throw e }
        if (old != null) confirmDeleted(state, old)
        Enrollment(ref.keyId, pub, generation, installId)
    }

    /** TEST ONLY: signs raw bytes. No production code may call it (release guard); production signing is [signBuilt] through SeedSyncWire, where native builds
     * every message. */
    internal fun signRawForTests(owner: String, message: ByteArray): ByteArray = signBuilt(owner) { message }

    /** Signs a message that [build] constructs from the [SignContext] of the very key that signs (key id, enrollment generation, install id, real native epoch),
     * read under the same lock. The durable document is read on every call: a denied, missing or unreadable state, or an unresolved erase intent or owed purge,
     * refuses the use. INTERNAL: only SeedSyncWire may call it. [build] must not call back into this core. */
    internal fun signBuilt(owner: String, build: (SignContext) -> ByteArray): ByteArray = synchronized(lock) {
        checkOwner(owner)
        if (owner in intents) fail(SyncKeyError.ERASE_INCOMPLETE)
        val state = load(owner)
        if (state.owed != Owed.NONE) fail(SyncKeyError.ERASE_INCOMPLETE)
        val active = state.active ?: fail(SyncKeyError.NOT_ENROLLED)
        val present = try { vault.containsAlias(active.alias) } catch (_: Exception) { fail(SyncKeyError.UNAVAILABLE) }
        if (!present) fail(SyncKeyError.MISSING_KEY)
        val message = build(SignContext(active.keyId, state.activeGeneration, state.activeInstall) {
            try { custody.readOwnerState(owner).epoch } catch (_: Exception) { fail(SyncKeyError.METADATA_UNAVAILABLE) }
        })
        try { vault.sign(active.alias, message) } catch (e: VaultException) {
            fail(if (e.kind == VaultException.Kind.INVALIDATED) SyncKeyError.MISSING_KEY else SyncKeyError.UNAVAILABLE)
        } catch (_: Exception) { fail(SyncKeyError.UNAVAILABLE) }
    }

    /** The one erase sequence for every purge trigger. [epoch] is the caller's bound (never above native state); erase captures the real native epoch to remove all owner records, even with a stale caller.
     * DISABLE is the persistent opt-out (clearOwner); every other trigger is a purge that leaves the preference alone. Always attempts every step.
     * A custody failure is rethrown after the key steps, and an uncommitted erase throws ERASE_INCOMPLETE, so a caller never mistakes either for success. */
    fun erase(owner: String, epoch: Long, trigger: EraseTrigger): EraseOutcome = synchronized(lock) {
        checkOwner(owner)
        eraseLocked(owner, epoch, trigger)
    }

    private fun eraseLocked(owner: String, epoch: Long, trigger: EraseTrigger): EraseOutcome {
        // The intent comes first and is in memory only: from here no use of this owner's key is possible in this process until the durable commit lands.
        intents[owner] = if (intents[owner] == EraseTrigger.DISABLE) EraseTrigger.DISABLE else trigger
        val state = try { load(owner) } catch (e: SyncKeyFailure) {
            // Unreadable document: no owner or alias is grounded, so nothing is deleted. Seeds are still purged; the intent stays for retryPending.
            try { if (trigger == EraseTrigger.DISABLE) custody.clearOwner(owner, epoch) else custody.purgeOwner(owner, epoch) } catch (_: Exception) {}
            throw e
        }
        // a. deny and owed, one atomic write. Nothing is used from this key afterwards.
        val victim = state.active
        val wantOwed = if (trigger == EraseTrigger.DISABLE || state.owed == Owed.DISABLE) Owed.DISABLE else Owed.PURGE
        if (victim != null) { state.deny.add(victim); state.active = null }
        // This layer erases the whole owner, not an epoch-scoped work ticket.
        // Every new erase captures native state again, including an erase while an older physical delete is still owed.
        val realEpoch = try { custody.readOwnerState(owner).epoch } catch (_: Exception) { null }
        if (realEpoch != null) state.owedEpoch = realEpoch
        state.owed = wantOwed
        var commitFailed = false
        try { save(state) } catch (_: SyncKeyFailure) {
            commitFailed = true
            if (victim != null) try { vault.delete(victim.alias) } catch (_: Exception) {} // intent not durable: remove the key itself anyway
        }
        if (!commitFailed) intents.remove(owner)
        var custodyFailure: Exception? = null
        var purged = false; var effective = epoch
        var keyDeleted = false
        try {
            // b. seeds. Whatever it throws, step c still runs (finally).
            try {
                if (!commitFailed && state.owedEpoch == null) throw CustodyFailure(CustodyError.METADATA_UNAVAILABLE)
                val useEpoch = if (realEpoch != null && epoch > realEpoch) epoch else state.owedEpoch ?: epoch
                val o = attemptOwed(owner, useEpoch, wantOwed)
                purged = o.first; effective = o.second
                if (purged && !commitFailed) clearOwed(state, wantOwed) // a failed clear only repeats an idempotent purge
            } catch (e: Exception) { custodyFailure = e }
        } finally {
            // c. delete and confirm absent. With a failed commit the document is stale, so only confirm state-recorded keys.
            if (!commitFailed) keyDeleted = confirmAll(state)
        }
        if (commitFailed) fail(SyncKeyError.ERASE_INCOMPLETE)
        custodyFailure?.let { throw it }
        return EraseOutcome(purged, keyDeleted, effective)
    }

    /** Persists owed=NONE. The in-memory value is restored if the write does not complete (exception or death), so a later write of this state never drops
     * a durable obligation that was not actually cleared. */
    private fun clearOwed(state: SyncState, was: Owed) {
        var done = false
        val epoch = state.owedEpoch
        try { state.owed = Owed.NONE; state.owedEpoch = null; save(state); done = true } catch (_: SyncKeyFailure) {} finally { if (!done) { state.owed = was; state.owedEpoch = epoch } }
    }

    /** Runs the owed seed step with [epoch]. Returns (seeds physically purged, effective epoch). Throws custody errors. */
    private fun attemptOwed(owner: String, epoch: Long, owed: Owed): Pair<Boolean, Long> =
        if (owed == Owed.DISABLE) { val p = custody.clearOwner(owner, epoch).purged; p to custody.readOwnerState(owner).epoch }
        else custody.purgeOwner(owner, epoch).let { it.purged to it.epoch }

    /** Repeat unresolved work for every owner: uncommitted erase intents, owed seed purges (replaying their durably captured epoch), and key deletions. Call at app
     * start, foreground and unlock. Owners are independent; unreadable documents are counted and left untouched. An unlistable store throws METADATA_UNAVAILABLE. */
    fun retryPending(): RetryResult = synchronized(lock) {
        val keys = try { store.keys() } catch (_: Exception) { fail(SyncKeyError.METADATA_UNAVAILABLE) }
        val owners = LinkedHashSet<String>(intents.keys)
        var unreadable = 0
        for (k in keys) {
            val owner = try {
                val text = store.read(k) ?: continue
                Base64.getUrlDecoder().decode(text.split('\n')[1].removePrefix("owner ")).toString(Charsets.UTF_8).also { require(ownerKey(it) == k && validCustodyId(it)) }
            } catch (_: Exception) { unreadable++; continue }
            owners.add(owner)
        }
        var keyLeft = 0; var owedLeft = 0
        for (owner in owners) {
            try {
                val state = load(owner)
                val intent = intents[owner]
                if (intent != null) { // commit the lost erase now, with the real epoch
                    eraseLocked(owner, custody.readOwnerState(owner).epoch, intent)
                } else if (state.owed != Owed.NONE) {
                    val actual = custody.readOwnerState(owner).epoch
                    if (state.owedEpoch == null || state.owedEpoch!! > actual) {
                        state.owedEpoch = actual
                        save(state) // never perform a transition before its retry epoch is durable
                    }
                    val o = attemptOwed(owner, state.owedEpoch!!, state.owed)
                    if (o.first) clearOwed(state, state.owed)
                }
            } catch (_: Exception) { /* isolated: counted below from the durable state */ }
            try {
                val st = load(owner)
                confirmAll(st)
                keyLeft += st.deny.size; if (st.owed != Owed.NONE || owner in intents) owedLeft++
            } catch (_: Exception) { unreadable++ }
        }
        RetryResult(keyLeft, owedLeft, unreadable)
    }

    /** Explicit recovery for ONE owner whose document is present but unusable (corrupt, wrong owner). Never automatic. Replaces it with an empty document that
     * owes a seed purge (the owner's state is unknown, so seeds are not trusted), clears any erase intent, and leaves the old alias unreferenced for
     * [sweepOrphans]. Refuses when the store cannot be read at all or the document is actually valid. */
    fun resetUnreadableState(owner: String) = synchronized(lock) {
        checkOwner(owner)
        val text = try { store.read(ownerKey(owner)) } catch (_: Exception) { fail(SyncKeyError.METADATA_UNAVAILABLE) } ?: return@synchronized
        if (runCatching { SyncState.decode(text, owner) }.isSuccess) fail(SyncKeyError.INVALID_INPUT)
        val fresh = SyncState(owner); fresh.owed = Owed.PURGE
        save(fresh); intents.remove(owner)
    }

    /** Removes seed-sync aliases that no durable document references (interrupted enrollment, reset documents). Aborts without deleting if any state is unreadable. */
    fun sweepOrphans(): Set<String> = synchronized(lock) {
        val referenced = HashSet<String>()
        try {
            for (k in store.keys()) {
                val text = store.read(k) ?: continue
                val owner = Base64.getUrlDecoder().decode(text.split('\n')[1].removePrefix("owner ")).toString(Charsets.UTF_8)
                require(ownerKey(owner) == k)
                val st = SyncState.decode(text, owner)
                st.active?.let { referenced.add(it.alias) }; st.deny.mapTo(referenced) { it.alias }
            }
        } catch (_: Exception) { fail(SyncKeyError.METADATA_UNAVAILABLE) }
        val orphans = try { vault.aliases().filter { it.startsWith(SYNC_ALIAS_PREFIX) && it !in referenced }.toSet() } catch (_: Exception) { fail(SyncKeyError.UNAVAILABLE) }
        orphans.forEach { try { vault.delete(it) } catch (_: Exception) {} }
        orphans
    }

    private fun confirmAll(state: SyncState): Boolean {
        var all = true
        for (d in state.deny.toList()) if (!confirmDeleted(state, d)) all = false
        return all
    }

    /** Delete, read back FRESH, and only then drop the deny record (persisted). A delete that throws but leaves the alias absent counts as gone; deleting an
     * absent alias is not an error. A present alias or an unreadable vault keeps the record. */
    private fun confirmDeleted(state: SyncState, ref: SyncKeyRef): Boolean {
        try { vault.delete(ref.alias) } catch (_: Exception) {}
        val gone = try { !vault.containsAlias(ref.alias) } catch (_: Exception) { false }
        if (!gone) return false
        state.deny.remove(ref)
        return try { save(state); true } catch (_: SyncKeyFailure) { false } // deny record stays on disk: harmless, retried, alias already absent
    }
}
