package org.otpanda.totp

import java.security.MessageDigest
import java.util.Base64

// Native seed custody v2: the Kotlin side of the Dart NativeSeedCustody contract (owner, entry, seed version, local epoch, version floors,
// minimum-accepted versions, snapshots, disable/enable, durable metadata). Pure JVM logic over KeyVault (platform key vault) and OwnerStateStore
// (durable non-secret metadata). No seed is ever stored or returned: the seed becomes a non-exportable vault key whose alias is the SHA-256 of the
// canonical AAD, so the key's identity is bound to owner, entry, version, algorithm, digits, period and epoch (see custodyAad). Not wired into the app.
//
// Protection is reported, not required: Android Keystore hardware is HARDWARE_HMAC, a software-backed Keystore key is OS_ENCRYPTED (user decision
// 2026-11-26 17:32: OS-encrypted software custody is allowed, no plaintext fallback). If the vault refuses, nothing is stored.

const val CUSTODY_MAX_SAFE_INT = 9007199254740991L
private const val ALIAS_PREFIX = "otpanda.totp.v2."
private const val STATE_HEADER = "otpanda-custody-state-v2"
private const val MAX_SNAPSHOT_ENTRIES = 5000 // tentative, same as the Dart contract

enum class CustodyError {
    UNAVAILABLE, LOCKED, MISSING_KEY, NOT_FOUND, TAMPER, VERSION_CONFLICT, STALE_EPOCH, EPOCH_MISMATCH, DENIED, DISABLED,
    STALE_SNAPSHOT, INVALID_SNAPSHOT, INVALID_INPUT, METADATA_UNAVAILABLE,
}

/** Carries only the error kind: never a seed, code, account id or platform message. */
class CustodyFailure(val error: CustodyError) : Exception(error.name)

enum class Protection { HARDWARE_HMAC, HARDWARE_WRAPPED, OS_ENCRYPTED, UNAVAILABLE }
data class Capability(val protection: Protection, val reason: String?)
data class CustodyOwnerState(val epoch: Long, val enabled: Boolean)

data class Snapshot(
    val epoch: Long, val revision: Long, val complete: Boolean,
    val versions: Map<String, Long>, val tombstones: Map<String, Long> = emptyMap(),
    /** Entries the server lists as unsupported or metadata-pending. A complete snapshot does not remove them by absence from [versions]. A tombstone still does. */
    val preserve: Set<String> = emptySet(),
) {
    /** SHA-256 over the canonical full statement (epoch, revision, complete, sorted versions, tombstones, preserve). Equal ids and values give an equal identity. */
    fun identity(): String {
        val t = buildString {
            append("e ").append(epoch).append("\nr ").append(revision).append("\nc ").append(if (complete) 1 else 0).append('\n')
            for ((e, v) in versions.toSortedMap()) append("v ").append(enc(e)).append(' ').append(v).append('\n')
            for ((e, v) in tombstones.toSortedMap()) append("t ").append(enc(e)).append(' ').append(v).append('\n')
            for (e in preserve.sorted()) append("p ").append(enc(e)).append('\n')
        }
        return java.security.MessageDigest.getInstance("SHA-256").digest(t.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    }
}

data class ReconcileOutcome(
    val removed: List<String>, val superseded: List<String>, val needsProvision: List<String>, val pendingPurge: List<String>,
)

/** One live entry's non-secret metadata. No seed, no key alias. [floor] and [minAccept] are the entry's persisted version marks for the current epoch. */
data class CatalogEntry(
    val entry: String, val version: Long, val epoch: Long, val algorithm: TotpCalculator.Algorithm, val digits: Int, val period: Int, val level: String,
    val floor: Long, val minAccept: Long,
)
/** Durable read-only catalog of one owner: the local preference (enabled is the default until an explicit opt-out) plus live entries and entries whose physical delete is pending. */
data class CustodyCatalog(val epoch: Long, val enabled: Boolean, val entries: List<CatalogEntry>, val pendingPurge: List<String>)

/** Outcome of an ordinary sign-out or owner-switch purge. It never changes the opt-out preference. */
data class PurgeOutcome(val purged: Boolean, val epoch: Long)

/** [denied] is always true once the call returns. [purged] is false while a physical delete is still pending. */
data class ClearOutcome(val purged: Boolean) { val denied: Boolean get() = true }

/** Durable non-secret metadata, one opaque text document per owner key. read/write/keys may throw IOException: custody then fails closed. */
interface OwnerStateStore {
    fun read(key: String): String?
    /** Atomic replace. A failed write must leave the previous document intact. */
    fun write(key: String, text: String)
    /** Every stored key. An unlistable store must throw, never return an empty set. */
    fun keys(): Set<String>
}

private val badId = Regex("[\\u0000-\\u001f\\u007f]")
fun validCustodyId(s: String) = s.isNotEmpty() && s.length <= 128 && !badId.containsMatchIn(s)

/** Same bytes as the Dart custodyAad: length-prefixed (4-byte big-endian) UTF-8 fields. */
fun custodyAad(owner: String, entry: String, version: Long, algorithm: TotpCalculator.Algorithm, digits: Int, period: Int, epoch: Long): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    fun field(text: String) {
        val b = text.toByteArray(Charsets.UTF_8)
        out.write(byteArrayOf((b.size ushr 24).toByte(), (b.size ushr 16).toByte(), (b.size ushr 8).toByte(), b.size.toByte()))
        out.write(b)
    }
    field("otpanda-native-seed-record-v1"); field(owner); field(entry); field("$version")
    field(algorithm.name.lowercase()); field("$digits"); field("$period"); field("$epoch")
    return out.toByteArray()
}

private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
private fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
fun custodyAlias(owner: String, entry: String, version: Long, algorithm: TotpCalculator.Algorithm, digits: Int, period: Int, epoch: Long) =
    ALIAS_PREFIX + hex(sha256(custodyAad(owner, entry, version, algorithm, digits, period, epoch)))
fun ownerKey(owner: String) = hex(sha256(owner.toByteArray(Charsets.UTF_8)))

private val b64e = Base64.getUrlEncoder().withoutPadding()
private val b64d = Base64.getUrlDecoder()
private fun enc(s: String) = b64e.encodeToString(s.toByteArray(Charsets.UTF_8))
private fun dec(s: String) = String(b64d.decode(s), Charsets.UTF_8)

internal class Rec(val entry: String, val version: Long, val epoch: Long, val algorithm: TotpCalculator.Algorithm, val digits: Int, val period: Int, val level: String, val alias: String)
internal data class Pend(val entry: String, val alias: String)
internal class Marks(var floor: Long = 0, var denyUp: Long = 0, var minAccept: Long = 0)

/** All durable state of one owner. Records here are LIVE only: a denied record moves to [pending] in the same write, so a live record is always usable. */
internal class OwnerState(val owner: String) {
    var epoch = 0L
    var disabled = false
    var snapEpoch = -1L // -1: none applied
    var snapRevision = 0L
    var snapIdentity = "" // empty: written before identities existed, so an equal revision is never replayed
    val records = LinkedHashMap<String, Rec>()
    val marks = HashMap<String, Marks>()
    val pending = ArrayList<Pend>()

    fun marksOf(entry: String) = marks.getOrPut(entry) { Marks() }
    fun deny(entry: String, version: Long) {
        val m = marksOf(entry)
        if (version > m.denyUp) m.denyUp = version
        if (version > m.floor) m.floor = version
    }
    fun retire(rec: Rec) { records.remove(rec.entry); pending.add(Pend(rec.entry, rec.alias)) }
    /** A local epoch rise: epoch-scoped marks start over and every record from an older epoch is denied. */
    fun advance(to: Long) {
        if (to <= epoch) return
        epoch = to
        marks.clear()
        for (r in records.values.filter { it.epoch < to }) retire(r)
    }

    fun encode(): String = buildString {
        append(STATE_HEADER).append('\n').append("owner ").append(enc(owner)).append('\n')
        append("epoch ").append(epoch).append('\n').append("disabled ").append(if (disabled) 1 else 0).append('\n')
        append(if (snapEpoch < 0) "snap none\n" else "snap $snapEpoch $snapRevision" + (if (snapIdentity.isEmpty()) "" else " $snapIdentity") + "\n")
        for ((e, m) in marks.toSortedMap()) if (m.floor > 0 || m.denyUp > 0 || m.minAccept > 0)
            append("mark ${enc(e)} ${m.floor} ${m.denyUp} ${m.minAccept}\n")
        for ((e, r) in records.toSortedMap()) append("rec ${enc(e)} ${r.version} ${r.epoch} ${r.algorithm.name} ${r.digits} ${r.period} ${r.level} ${r.alias}\n")
        for (p in pending.sortedWith(compareBy({ it.entry }, { it.alias }))) append("pend ${enc(p.entry)} ${p.alias}\n")
        append("end\n")
    }

    companion object {
        /** Strict: exact grammar, canonical re-encoding, owner must match. Anything else is unusable (custody fails closed), never partially read. */
        fun decode(text: String, expectedOwner: String): OwnerState {
            require(text.length <= 1_048_576)
            val lines = text.split('\n')
            require(lines.size >= 7 && lines.last().isEmpty() && lines[lines.size - 2] == "end" && lines[0] == STATE_HEADER)
            val owner = lines[1].removePrefix("owner ").also { require(lines[1].startsWith("owner ")) }.let(::dec)
            require(owner == expectedOwner && validCustodyId(owner))
            val s = OwnerState(owner)
            s.epoch = lines[2].removePrefix("epoch ").also { require(lines[2].startsWith("epoch ")) }.toLong()
            require(s.epoch in 0 until CUSTODY_MAX_SAFE_INT)
            require(lines[3] == "disabled 0" || lines[3] == "disabled 1"); s.disabled = lines[3] == "disabled 1"
            if (lines[4] != "snap none") {
                val p = lines[4].split(' '); require((p.size == 3 || p.size == 4) && p[0] == "snap")
                if (p.size == 4) { require(p[3].matches(Regex("[0-9a-f]{64}"))); s.snapIdentity = p[3] }
                s.snapEpoch = p[1].toLong(); s.snapRevision = p[2].toLong()
                require(s.snapEpoch in 0 until CUSTODY_MAX_SAFE_INT && s.snapRevision in 1..CUSTODY_MAX_SAFE_INT)
            }
            for (i in 5 until lines.size - 2) {
                val p = lines[i].split(' ')
                when (p[0]) {
                    "mark" -> { require(p.size == 5); val m = Marks(p[2].toLong(), p[3].toLong(), p[4].toLong())
                        require(m.floor in 0..CUSTODY_MAX_SAFE_INT && m.denyUp in 0..CUSTODY_MAX_SAFE_INT && m.minAccept in 0..CUSTODY_MAX_SAFE_INT)
                        require(s.marks.put(dec(p[1]), m) == null) }
                    "rec" -> { require(p.size == 9); val e = dec(p[1])
                        val alg = TotpCalculator.Algorithm.entries.first { it.name == p[4] }
                        val r = Rec(e, p[2].toLong(), p[3].toLong(), alg, p[5].toInt(), p[6].toInt(), p[7], p[8])
                        require(validCustodyId(e) && r.version in 1..CUSTODY_MAX_SAFE_INT && r.epoch in 0 until CUSTODY_MAX_SAFE_INT)
                        require(r.digits in 6..8 && r.period in 1..86400 && r.level.matches(Regex("[a-z0-9_-]{1,32}")) && r.alias.matches(Regex("$ALIAS_PREFIX[0-9a-f]{64}")))
                        require(s.records.put(e, r) == null) }
                    "pend" -> { require(p.size == 3); val e = dec(p[1]); require(validCustodyId(e) && p[2].matches(Regex("$ALIAS_PREFIX[0-9a-f]{64}"))); s.pending.add(Pend(e, p[2])) }
                    else -> throw IllegalArgumentException("line")
                }
            }
            require(s.encode() == text) { "not canonical" }
            return s
        }
    }
}

class NativeSeedCustodyCore(private val vault: KeyVault, private val store: OwnerStateStore) {
    private val lock = Any()

    private fun fail(e: CustodyError): Nothing = throw CustodyFailure(e)
    private fun load(owner: String): OwnerState = try {
        store.read(ownerKey(owner))?.let { OwnerState.decode(it, owner) } ?: OwnerState(owner)
    } catch (_: Exception) { fail(CustodyError.METADATA_UNAVAILABLE) }
    private fun save(state: OwnerState) {
        try { store.write(ownerKey(state.owner), state.encode()) } catch (_: Exception) { fail(CustodyError.METADATA_UNAVAILABLE) }
    }
    private fun checkEpoch(e: Long) { if (e < 0 || e >= CUSTODY_MAX_SAFE_INT) fail(CustodyError.INVALID_INPUT) }
    private fun checkVersion(v: Long) { if (v < 1 || v > CUSTODY_MAX_SAFE_INT) fail(CustodyError.INVALID_INPUT) }
    private fun checkIds(vararg ids: String) { if (!ids.all(::validCustodyId)) fail(CustodyError.INVALID_INPUT) }

    /** Tries every pending physical delete; the logical state is already saved. Returns true when none is left. A failed save here only leaves
     * already-deleted aliases pending, which is harmless (deleting an absent alias succeeds). */
    private fun purge(state: OwnerState): Boolean {
        var changed = false
        for (p in state.pending.toList()) {
            val ok = try { vault.delete(p.alias); true } catch (_: Exception) { false }
            if (ok) { state.pending.remove(p); changed = true }
        }
        if (changed) runCatching { save(state) }
        return state.pending.isEmpty()
    }

    /** The protection level the vault reported when the live record was stored (e.g. secure_hardware, software), or null. No secrets. */
    fun levelOf(owner: String, entry: String): String? = synchronized(lock) { checkIds(owner, entry); load(owner).records[entry]?.level }

    /** Read-only local opt-out metadata. Does not authorize sync or create keys. */
    fun readOwnerState(owner: String): CustodyOwnerState = synchronized(lock) {
        checkIds(owner)
        val state = load(owner)
        CustodyOwnerState(state.epoch, !state.disabled)
    }

    fun capability(): Capability = try {
        val r = vault.probe()
        Capability(if (r.insideSecureHardware) Protection.HARDWARE_HMAC else Protection.OS_ENCRYPTED, null)
    } catch (e: VaultException) { Capability(Protection.UNAVAILABLE, "vault_" + e.kind.name.lowercase()) }

    fun provision(owner: String, entry: String, seedVersion: Long, algorithm: TotpCalculator.Algorithm, digits: Int, period: Int, seed: ByteArray, epoch: Long) =
        synchronized(lock) {
            try {
                checkIds(owner, entry); checkVersion(seedVersion); checkEpoch(epoch)
                if (digits !in 6..8 || period !in 1..86400 || seed.size !in LocalSeedCustody.MIN_SEED..LocalSeedCustody.MAX_SEED) fail(CustodyError.INVALID_INPUT)
                val state = load(owner)
                if (state.disabled) fail(CustodyError.DISABLED)
                if (epoch < state.epoch) fail(CustodyError.STALE_EPOCH)
                if (epoch > state.epoch) fail(CustodyError.EPOCH_MISMATCH) // only local lifecycle transitions advance the epoch
                val m = state.marks[entry]
                if (m != null && (seedVersion <= m.floor || seedVersion < m.minAccept)) fail(CustodyError.VERSION_CONFLICT)
                val old = state.records[entry]
                if (old != null && seedVersion <= old.version) fail(CustodyError.VERSION_CONFLICT)
                val alias = custodyAlias(owner, entry, seedVersion, algorithm, digits, period, epoch)
                try { if (vault.containsAlias(alias)) vault.delete(alias) } catch (_: VaultException) { fail(CustodyError.UNAVAILABLE) }
                val report = try { vault.importSeed(alias, seed, algorithm) } catch (e: VaultException) {
                    runCatching { vault.delete(alias) }
                    fail(when (e.kind) { VaultException.Kind.LOCKED -> CustodyError.LOCKED; VaultException.Kind.UNSUPPORTED_SEED -> CustodyError.INVALID_INPUT; else -> CustodyError.UNAVAILABLE })
                }
                if (old != null) state.retire(old)
                state.records[entry] = Rec(entry, seedVersion, epoch, algorithm, digits, period, report.level, alias)
                state.marksOf(entry).floor = seedVersion
                try { save(state) } catch (e: CustodyFailure) { runCatching { vault.delete(alias) }; throw e }
                purge(state)
                Unit
            } finally { seed.fill(0) }
        }

    fun generate(owner: String, entry: String, seedVersion: Long, unixSeconds: Long): String = synchronized(lock) {
        checkIds(owner, entry); checkVersion(seedVersion)
        val state = load(owner)
        val rec = state.records[entry]
        if (rec == null) fail(if (state.pending.any { it.entry == entry }) CustodyError.DENIED else CustodyError.NOT_FOUND)
        if (state.disabled) fail(CustodyError.DENIED)
        if (rec.alias != custodyAlias(owner, entry, rec.version, rec.algorithm, rec.digits, rec.period, rec.epoch)) fail(CustodyError.TAMPER)
        val key = try { vault.key(rec.alias) } catch (e: VaultException) {
            fail(when (e.kind) { VaultException.Kind.LOCKED -> CustodyError.LOCKED; VaultException.Kind.INVALIDATED -> CustodyError.MISSING_KEY; else -> CustodyError.UNAVAILABLE })
        } ?: fail(CustodyError.MISSING_KEY)
        if (key.algorithm != rec.algorithm.jcaName) fail(CustodyError.TAMPER)
        if (rec.version != seedVersion) fail(CustodyError.VERSION_CONFLICT)
        try { TotpCalculator.generate(key, unixSeconds, rec.algorithm, rec.digits, rec.period).code }
        catch (_: IllegalArgumentException) { fail(CustodyError.INVALID_INPUT) }
        catch (e: Exception) {
            fail(when (classifyKeyFailure(e)) { is CodeResult.Locked -> CustodyError.LOCKED; is CodeResult.Invalidated -> CustodyError.MISSING_KEY; else -> CustodyError.UNAVAILABLE })
        }
    }

    /** Deletes the entry up to [seedVersion] (required). Records the floor even without a record, so an in-flight provision at or below it cannot resurrect. */
    fun delete(owner: String, entry: String, seedVersion: Long) = synchronized(lock) {
        checkIds(owner, entry); checkVersion(seedVersion)
        val state = load(owner)
        state.deny(entry, seedVersion)
        state.records[entry]?.let { if (it.version <= seedVersion) state.retire(it) }
        save(state)
        purge(state)
        Unit
    }

    fun clearOwner(owner: String, epoch: Long): ClearOutcome = synchronized(lock) {
        checkIds(owner); checkEpoch(epoch)
        val state = load(owner)
        if (epoch > state.epoch) fail(CustodyError.EPOCH_MISMATCH) // same bound as purgeOwner
        if (epoch + 1 > state.epoch) { state.disabled = true; state.advance(epoch + 1) }
        for (r in state.records.values.filter { it.epoch <= epoch }) state.retire(r) // never a newer epoch
        save(state)
        val before = state.pending.size
        purge(state)
        ClearOutcome(purged = state.pending.isEmpty() || before == 0)
    }

    /** Ordinary sign-out or owner switch: removes this owner's local keys and denies every older epoch, but is NOT an opt-out. The persisted preference
     * (default enabled, or an explicit opt-out) is left exactly as it was, so a later sign-in needs no enableOwner and an explicit opt-out is not lost.
     * Contrast [clearOwner], which is the persistent opt-out. Same epoch rule: provisions after this call must use the returned owner epoch. */
    fun purgeOwner(owner: String, epoch: Long): PurgeOutcome = synchronized(lock) {
        checkIds(owner); checkEpoch(epoch)
        val state = load(owner)
        if (epoch > state.epoch) fail(CustodyError.EPOCH_MISMATCH) // a caller cannot burn the epoch ahead of the real owner state
        state.advance(epoch + 1) // no-op when the owner is already past it
        for (r in state.records.values.filter { it.epoch <= epoch }) state.retire(r) // never a newer epoch
        save(state)
        val before = state.pending.size
        purge(state)
        PurgeOutcome(purged = state.pending.isEmpty() || before == 0, epoch = state.epoch)
    }

    /** Durable read-only per-entry metadata and version marks, for restart. Does not touch the vault, create keys, mutate state or authorize sync.
     * Unreadable or non-canonical state fails closed with METADATA_UNAVAILABLE. */
    fun readCatalog(owner: String): CustodyCatalog = synchronized(lock) {
        checkIds(owner)
        val state = load(owner)
        CustodyCatalog(
            state.epoch, !state.disabled,
            if (state.disabled) emptyList() else state.records.toSortedMap().values.map { r -> // an opted-out owner exposes no entries, even if a delete is pending
                val m = state.marks[r.entry]
                CatalogEntry(r.entry, r.version, r.epoch, r.algorithm, r.digits, r.period, r.level, m?.floor ?: 0L, m?.minAccept ?: 0L)
            },
            state.pending.map { it.entry }.distinct().sorted(),
        )
    }

    fun enableOwner(owner: String, epoch: Long) = synchronized(lock) {
        checkIds(owner); checkEpoch(epoch)
        val state = load(owner)
        if (epoch < state.epoch) fail(CustodyError.STALE_EPOCH)
        state.advance(epoch)
        state.disabled = false
        save(state)
        purge(state)
        Unit
    }

    /** Retries every pending physical delete. Returns the still-pending `owner/entry` identifiers. */
    fun purgePending(): List<String> = synchronized(lock) {
        val keys = try { store.keys() } catch (_: Exception) { fail(CustodyError.METADATA_UNAVAILABLE) }
        val left = ArrayList<String>()
        for (k in keys) {
            val text = try { store.read(k) } catch (_: Exception) { fail(CustodyError.METADATA_UNAVAILABLE) } ?: continue
            val owner = try { ownerOf(text, k) } catch (_: Exception) { fail(CustodyError.METADATA_UNAVAILABLE) }
            val state = load(owner)
            purge(state)
            state.pending.mapTo(left) { "$owner/${it.entry}" }
        }
        left.sorted()
    }

    private fun ownerOf(text: String, key: String): String {
        val owner = dec(text.split('\n')[1].removePrefix("owner "))
        require(ownerKey(owner) == key)
        return owner
    }

    fun reconcile(owner: String, s: Snapshot): ReconcileOutcome = synchronized(lock) {
        checkIds(owner)
        fun bad(): Nothing = fail(CustodyError.INVALID_SNAPSHOT)
        if (s.epoch < 0 || s.epoch >= CUSTODY_MAX_SAFE_INT || s.revision < 1 || s.revision > CUSTODY_MAX_SAFE_INT ||
            s.versions.size > MAX_SNAPSHOT_ENTRIES || s.tombstones.size > MAX_SNAPSHOT_ENTRIES) bad()
        for (m in listOf(s.versions, s.tombstones)) for ((e, v) in m) if (!validCustodyId(e) || v < 1 || v > CUSTODY_MAX_SAFE_INT) bad()
        if (s.preserve.size > MAX_SNAPSHOT_ENTRIES || s.preserve.any { !validCustodyId(it) || s.versions.containsKey(it) }) bad()
        for ((e, v) in s.versions) { val t = s.tombstones[e]; if (t != null && v <= t) bad() }
        val state = load(owner)
        if (state.disabled) fail(CustodyError.DISABLED)
        if (s.epoch < state.epoch) fail(CustodyError.STALE_EPOCH)
        if (s.epoch > state.epoch) fail(CustodyError.EPOCH_MISMATCH)
        val identity = s.identity()
        // Equal (epoch, revision) is replayed only when the durably recorded full statement is identical. Lower, or equal with a different or unknown identity, is stale.
        val replay = state.snapEpoch == s.epoch && s.revision == state.snapRevision && state.snapIdentity.isNotEmpty() && state.snapIdentity == identity
        if (state.snapEpoch >= 0 && !replay && (s.epoch < state.snapEpoch || (s.epoch == state.snapEpoch && s.revision <= state.snapRevision))) fail(CustodyError.STALE_SNAPSHOT)
        state.snapEpoch = s.epoch; state.snapRevision = s.revision; state.snapIdentity = identity
        for ((e, v) in s.versions) { val m = state.marksOf(e); if (v > m.minAccept) m.minAccept = v }
        val removed = ArrayList<String>(); val superseded = ArrayList<String>()
        for (r in state.records.values.toList()) {
            val t = s.tombstones[r.entry]
            val gone = (t != null && r.version <= t) || (s.complete && !s.versions.containsKey(r.entry) && r.entry !in s.preserve && t == null)
            val listed = s.versions[r.entry]
            if (gone) { state.deny(r.entry, r.version); removed.add(r.entry); state.retire(r) }
            else if (listed != null && listed > r.version) { state.deny(r.entry, r.version); superseded.add(r.entry); state.retire(r) }
        }
        for ((e, t) in s.tombstones) state.deny(e, t)
        val need = s.versions.entries.filter { (e, v) -> v > maxOf(state.records[e]?.version ?: 0L, state.marks[e]?.floor ?: 0L) }.map { it.key }
        save(state)
        purge(state)
        ReconcileOutcome(removed.sorted(), superseded.sorted(), need.sorted(), state.pending.map { it.entry }.distinct().sorted())
    }

    /** Removes v2 keys that no state document references (interrupted provision). Aborts without deleting anything if any state is unreadable. */
    fun sweepOrphans(): Set<String> = synchronized(lock) {
        val referenced = HashSet<String>()
        try {
            for (k in store.keys()) {
                val text = store.read(k) ?: continue
                val st = OwnerState.decode(text, ownerOf(text, k))
                st.records.values.mapTo(referenced) { it.alias }; st.pending.mapTo(referenced) { it.alias }
            }
        } catch (_: Exception) { fail(CustodyError.METADATA_UNAVAILABLE) }
        val orphans = try { vault.aliases().filter { it.startsWith(ALIAS_PREFIX) && it !in referenced }.toSet() } catch (_: VaultException) { fail(CustodyError.UNAVAILABLE) }
        orphans.forEach { runCatching { vault.delete(it) } }
        orphans
    }
}
