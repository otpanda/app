package org.otpanda.totp

import java.security.SecureRandom

// UNREGISTERED seed-sync channel contract (design v4). Pure JVM, no Flutter or Android types, so it runs in the JVM suite. A host would forward (method, arguments)
// exactly like NativeCustodyChannelHandler; nothing here is registered, and the release guard forbids constructing it outside this file and the tests.
//
// Rules of the contract (the Dart side mirrors them):
//  * Native builds every signed message. Dart passes only what the server said (challenge, expiresAt, actionDigest, state, entry specs from its own signed snapshot).
//    ownerId, keyId and the proof label never cross the channel as inputs (native supplies them). installId is the exception: Dart persists it and passes it to syncEnroll, and native pins it and refuses a different one. Time is the native clock: Dart never supplies "now".
//  * A seed never leaves native: sealed entries are opened and handed to custody inside the guarded provision step. No reply carries seed, key or ciphertext bytes.
//  * Arguments are a Map with EXACTLY the listed keys. Long or Int for numbers (never Double or String), String for text. Anything else is INVALID_INPUT.
//  * Errors carry a code only: a SyncKeyError name, "INVALID_INPUT", "BUSY", or "WIRE_<REASON>" (the wire reason up to its first ':', upper case).
//    WIRE_EPOCH, WIRE_INACTIVE, WIRE_EXPIRED, WIRE_STATE, WIRE_STATUS and every other refusal mean: change nothing, never purge; for a batch, start a fresh begin.
//  * Batch handles are native objects named by a random handleId. At most [MAX_HANDLES] live at once; a handle ends when it is DONE or DISCARDED, when the
//    host calls syncBatchFinish, or when [HANDLE_TTL_MS] passes after begin. Dead handles are swept on every call.
//
// Methods (reply on success):
//   syncEnroll {owner, installId, generation} -> {keyId, publicKey(bytes), generation, installId}
//   syncEnrollmentState {owner} -> {keyId or null, provable:Boolean}   (provable: this process made the active enrollment and can still sign its enroll proof)
//   syncSignEnrollProof {owner, challenge, actionDigest, expiresAt, keyId} -> signature (86-char base64url)   [keyId = the id syncEnroll returned]
//   syncSignSnapshotProof {owner, deviceId, generation, epoch, challenge, expiresAt, keyId} -> signature
//   syncSignRevokeProof {owner, deviceId, generation, challenge, expiresAt, keyId} -> signature
//   syncBatchBegin {owner, deviceId, generation, epoch, entries:[{entryId, seedVersion, algorithm, digits, periodSeconds}]} -> {handleId, ephemeralPublic}
//   syncBatchBind {handleId, challenge, expiresAt} -> null         syncBatchSign {handleId} -> signature
//   syncBatchOpen {handleId, entryId, serverPublicKey, nonce, ciphertext} -> {pending:[entryIds]}   (provisions into custody; refuses epoch/inactive)
//   syncBatchSkip {handleId, entryId} -> {pending:[...]}           syncBatchFinish {handleId} -> null (idempotent, also for an unknown handle)
//   syncDiscoverOwners {} -> {owners:[{owner, keyId or null, pending:Boolean}], unreadable:Long, complete:Boolean}   (durable, no session or bearer needed)
//   syncStatusKeyId {owner} -> keyId or null (null: nothing to ask; make no status request)
//   syncStatusSign {owner, keyId, challenge, expiresAt} -> signature
//   syncStatusApply {owner, keyId, state} -> {outcome:"kept"|"purged"|"noop"|"pending"|"unreadable"}
//   syncErase {owner, epoch, trigger:"sign_out"|"disable"|"owner_switch"} -> {seedsPurged, keyDeleted, epoch}   (remote triggers exist only through syncStatusApply)
//   syncRetryPending {} -> {keyDeletesPending, purgesOwed, unreadableOwners}
// syncBatchOpen and a failed syncBatchSign discard the whole handle. syncBatchFinish ONLY discards: it never signs, opens or provisions.
//
// Owner discovery for the status loop: syncDiscoverOwners lists every owner with a seed-sync document, from the same durable store as syncRetryPending. keyId is the active
// key (null when none or while an erase is pending); pending=true means an erase, owed purge or key delete is unresolved (call syncRetryPending, send no status request for
// that owner). complete=false (unreadable>0) means some documents could not be read and were left untouched: the list is NOT the whole truth, retry later and never treat
// it as "nothing to check". An unlistable store is the error METADATA_UNAVAILABLE, never an empty list. Only owner and keyId are disclosed (no alias, install id, generation).
//
// Dart contract (typed, none of these is a purge reason except a successful syncStatusApply "purged" or an explicit syncErase):
//  * Any SyncKeyError code (MISSING_KEY, UNAVAILABLE, METADATA_UNAVAILABLE, NOT_ENROLLED, ERASE_INCOMPLETE, INVALID_INPUT) and every WIRE_* code: change nothing, never
//    purge. MISSING_KEY means the signing key is gone: tell the user sync needs enrolling again; seeds stay until a definitive remote code or explicit erase.
//  * syncStatusKeyId null: make NO status request (not enrolled, erase pending or state unreadable). BUSY: retry the begin later.
//  * syncStatusApply: "kept" nothing to do. "purged" done (this owner's batch handles were discarded). "noop": the asked key is no longer the active key or is already
//    gone with nothing pending: TERMINAL, do not retry. "pending": an erase or key delete is already owed: call syncRetryPending, send no new status request.
//    "unreadable": the enrollment document cannot be read, nothing changed: retry later, never treat as purge. WIRE_STATUS (unknown state string): retry later.
//  * Half enrollment: syncEnroll makes a durable ACTIVE key but only this process holds the public point the enroll proof needs. After a process death before the
//    server accepted it, syncEnrollmentState gives provable=false and syncSignEnrollProof gives WIRE_KEY. If Dart has no record that the server confirmed that key,
//    it repairs by calling syncEnroll again: the old key is denied and deleted first, the new key is the only active one, and no seed is touched.
//  * installId: Dart is the single source (a random per-install id it persists, 22 to 64 chars of [A-Za-z0-9_-]). Native pins it in the enrollment record and refuses
//    a different id for the same owner while an enrollment is active (INVALID_INPUT). There is no native install id in this base.
//  * Erase, a status purge and re-enrollment discard that owner's live batch handles at once, so nothing begun under the old key can sign or provision.
//
// Lock order (always this direction, never reversed): channel lock -> handle lock -> core lock -> custody lock. Erase, status apply and enroll run under the channel
// lock, so a concurrent erase through the handler waits for an open in progress and then purges what it provisioned; an erase straight on the core waits on the core
// lock the same way. The provision callback must not call back into the handler or the core.

class SeedSyncChannelHandler(
    private val core: SeedSyncKeyCore,
    private val custody: NativeSeedCustodyCore,
    private val clockMs: () -> Long,
    private val random: SecureRandom = SecureRandom(),
    /** Receives the seed INSIDE the guarded provision step. Default: custody, which zeroes the array it is given. The handle zeroes the same array again. Never copy it. */
    private val provisioner: (String, SealedEntrySpec, ByteArray, Long) -> Unit = { owner, spec, seed, epoch ->
        custody.provision(owner, spec.entryId, spec.seedVersion, wireAlgorithm(spec.algorithm), spec.digits, spec.period, seed, epoch)
    },
) {
    companion object { const val MAX_HANDLES = 4; const val HANDLE_TTL_MS = 150_000L }

    private class Bad : Exception()
    private class Live(val owner: String, val epoch: Long, val handle: SeedSyncBatchHandle, val bornMs: Long)

    private val lock = Any()
    private val handles = LinkedHashMap<String, Live>()
    /** The last enrollment per owner, in memory only: the public point is not persisted (the state document holds ids only), and the enroll proof needs it to
     * recompute the action digest. After a process restart an unfinished enrollment cannot be proven; the caller enrolls again (a fresh key). */
    private val enrolled = HashMap<String, Enrollment>()

    private fun Map<*, *>.str(k: String) = (this[k] as? String) ?: throw Bad()
    private fun Map<*, *>.long(k: String): Long = when (val v = this[k]) { is Long -> v; is Int -> v.toLong(); else -> throw Bad() }
    private fun Map<*, *>.int(k: String): Int { val v = long(k); if (v < Int.MIN_VALUE || v > Int.MAX_VALUE) throw Bad(); return v.toInt() }
    private fun Map<*, *>.exact(vararg keys: String) { if (this.keys != keys.toSet()) throw Bad() }

    private val known = setOf("syncEnroll", "syncEnrollmentState", "syncSignEnrollProof", "syncSignSnapshotProof", "syncSignRevokeProof", "syncBatchBegin", "syncBatchBind", "syncBatchSign",
        "syncBatchOpen", "syncBatchSkip", "syncBatchFinish", "syncDiscoverOwners", "syncStatusKeyId", "syncStatusSign", "syncStatusApply", "syncErase", "syncRetryPending")

    private fun sweep(now: Long) {
        val it = handles.entries.iterator()
        while (it.hasNext()) {
            val e = it.next().value
            val dead = e.handle.state == SeedSyncBatchHandle.State.DONE || e.handle.state == SeedSyncBatchHandle.State.DISCARDED
            if (dead || now - e.bornMs >= HANDLE_TTL_MS || now < e.bornMs) { e.handle.discard(); it.remove() }
        }
    }
    /** Discards every live handle of [owner] now (erase, status purge, re-enrollment). Caller holds [lock]. A discarded handle can no longer sign or provision. */
    private fun discardOwner(owner: String) {
        val it = handles.entries.iterator()
        while (it.hasNext()) { val e = it.next().value; if (e.owner == owner) { e.handle.discard(); it.remove() } }
    }
    private fun live(a: Map<*, *>): Live = synchronized(lock) { handles[a.str("handleId")] ?: throw WireException("state") }
    private fun pending(l: Live) = ChannelReply.Ok(mapOf("pending" to l.handle.pendingEntries().sorted()))

    private fun trigger(name: String) = when (name) {
        "sign_out" -> EraseTrigger.SIGN_OUT; "disable" -> EraseTrigger.DISABLE; "owner_switch" -> EraseTrigger.OWNER_SWITCH; else -> throw Bad()
    }

    fun handle(method: String, arguments: Any?): ChannelReply {
        if (method !in known) return ChannelReply.NotImplemented
        return try {
            val a = arguments as? Map<*, *> ?: if (method == "syncRetryPending" || method == "syncDiscoverOwners") emptyMap<Any, Any>() else throw Bad()
            val now = clockMs()
            when (method) {
                "syncEnroll" -> { a.exact("owner", "installId", "generation"); val owner = a.str("owner"); val install = a.str("installId")
                    synchronized(lock) {
                        // Dart is the single source of installId (a random per-install id it persists). Native pins it in the enrollment record and refuses a different one
                        // for the same owner while an enrollment is active: an id that changes inside one install is a bug or tampering, never a repair.
                        core.installIdFor(owner)?.let { if (it != install) return ChannelReply.Err("INVALID_INPUT") }
                        try {
                            core.enroll(owner, install, a.long("generation")).let { enrolled[owner] = it
                                ChannelReply.Ok(mapOf("keyId" to it.keyId, "publicKey" to it.publicKey.copyOf(), "generation" to it.generation, "installId" to it.installId)) }
                        } finally { discardOwner(owner) } // a new key invalidates every batch begun under the old one
                    } }
                "syncEnrollmentState" -> { a.exact("owner"); val owner = a.str("owner"); synchronized(lock) {
                    val kid = SeedSyncWire.statusKeyId(core, owner)
                    ChannelReply.Ok(mapOf("keyId" to kid, "provable" to (kid != null && enrolled[owner]?.keyId == kid))) } }
                "syncSignEnrollProof" -> { a.exact("owner", "challenge", "actionDigest", "expiresAt", "keyId"); val owner = a.str("owner")
                    // the asked keyId must be the enrollment this process made; signEnrollProof then requires it to still be the ACTIVE key
                    val en = synchronized(lock) { enrolled[owner] }?.takeIf { it.keyId == a.str("keyId") } ?: throw WireException("key")
                    ChannelReply.Ok(SeedSyncWire.signEnrollProof(core, owner, en, a.str("challenge"), a.str("actionDigest"), a.long("expiresAt"), now)) }
                "syncSignSnapshotProof" -> { a.exact("owner", "deviceId", "generation", "epoch", "challenge", "expiresAt", "keyId")
                    ChannelReply.Ok(SeedSyncWire.signProof(core, a.str("owner"), SyncPurpose.SNAPSHOT, mapOf("deviceId" to a.str("deviceId"), "generation" to a.long("generation"),
                        "epoch" to a.long("epoch"), "challenge" to a.str("challenge"), "expiresAt" to a.long("expiresAt")), now, a.str("keyId"))) }
                "syncSignRevokeProof" -> { a.exact("owner", "deviceId", "generation", "challenge", "expiresAt", "keyId")
                    ChannelReply.Ok(SeedSyncWire.signProof(core, a.str("owner"), SyncPurpose.REVOKE, mapOf("deviceId" to a.str("deviceId"), "generation" to a.long("generation"),
                        "challenge" to a.str("challenge"), "expiresAt" to a.long("expiresAt")), now, a.str("keyId"))) }
                "syncDiscoverOwners" -> { a.exact(); core.discoverOwners().let { d ->
                    ChannelReply.Ok(mapOf("owners" to d.owners.map { mapOf("owner" to it.owner, "keyId" to it.keyId, "pending" to it.pending) }, "unreadable" to d.unreadable.toLong(), "complete" to d.complete)) } }
                "syncStatusKeyId" -> { a.exact("owner"); ChannelReply.Ok(SeedSyncWire.statusKeyId(core, a.str("owner"))) }
                "syncStatusSign" -> { a.exact("owner", "keyId", "challenge", "expiresAt")
                    ChannelReply.Ok(SeedSyncWire.signStatusProof(core, a.str("owner"), a.str("challenge"), a.long("expiresAt"), now, a.str("keyId"))) }
                "syncStatusApply" -> { a.exact("owner", "keyId", "state"); val owner = a.str("owner")
                    synchronized(lock) {
                        val outcome = try { SeedSyncWire.applyStatus(core, owner, a.str("keyId"), a["state"] as? String ?: throw Bad()) }
                            catch (e: WireException) { throw e } catch (e: Bad) { throw e } catch (e: Throwable) { discardOwner(owner); throw e } // a failure after the deny step still ended the key
                        if (outcome == SeedSyncWire.StatusOutcome.PURGED) { discardOwner(owner); enrolled.remove(owner) }
                        ChannelReply.Ok(mapOf("outcome" to outcome.name.lowercase()))
                    } }
                "syncErase" -> { a.exact("owner", "epoch", "trigger"); val owner = a.str("owner"); val tr = trigger(a.str("trigger"))
                    synchronized(lock) {
                        try { core.erase(owner, a.long("epoch"), tr).let { ChannelReply.Ok(mapOf("seedsPurged" to it.seedsPurged, "keyDeleted" to it.keyDeleted, "epoch" to it.epoch)) } }
                        finally { discardOwner(owner); enrolled.remove(owner) }
                    } }
                "syncRetryPending" -> { a.exact(); core.retryPending().let { ChannelReply.Ok(mapOf("keyDeletesPending" to it.keyDeletesPending.toLong(), "purgesOwed" to it.purgesOwed.toLong(), "unreadableOwners" to it.unreadableOwners.toLong())) } }
                "syncBatchBegin" -> { a.exact("owner", "deviceId", "generation", "epoch", "entries")
                    val specs = (a["entries"] as? List<*> ?: throw Bad()).map { e ->
                        val m = e as? Map<*, *> ?: throw Bad(); m.exact("entryId", "seedVersion", "algorithm", "digits", "periodSeconds")
                        SealedEntrySpec(m.str("entryId"), m.long("seedVersion"), m.str("algorithm"), m.int("digits"), m.int("periodSeconds"))
                    }
                    synchronized(lock) {
                        sweep(now)
                        if (handles.size >= MAX_HANDLES) return ChannelReply.Err("BUSY")
                        val owner = a.str("owner")
                        val h = SeedSyncBatchHandle.begin(core, owner, a.str("deviceId"), a.long("generation"), a.long("epoch"), specs)
                        val id = ByteArray(16).also { random.nextBytes(it) }.joinToString("") { "%02x".format(it) }
                        handles[id] = Live(owner, a.long("epoch"), h, now)
                        ChannelReply.Ok(mapOf("handleId" to id, "ephemeralPublic" to h.ephemeralPublic()))
                    } }
                "syncBatchBind" -> { a.exact("handleId", "challenge", "expiresAt"); synchronized(lock) { sweep(now); live(a).handle.bind(a.str("challenge"), a.long("expiresAt"), now) }; ChannelReply.Ok(null) }
                "syncBatchSign" -> { a.exact("handleId"); synchronized(lock) { sweep(now); ChannelReply.Ok(live(a).handle.signProof(now)) } }
                "syncBatchOpen" -> { a.exact("handleId", "entryId", "serverPublicKey", "nonce", "ciphertext"); synchronized(lock) {
                    sweep(now); val l = live(a)
                    // provisioning happens inside the guarded step: the seed goes straight into custody at the handle's epoch, and custody keeps its own copy
                    l.handle.open(a.str("entryId"), a.str("serverPublicKey"), a.str("nonce"), a.str("ciphertext"), now) { spec, seed ->
                        provisioner(l.owner, spec, seed, l.epoch)
                    }
                    sweep(now); pending(l) } }
                "syncBatchSkip" -> { a.exact("handleId", "entryId"); synchronized(lock) { sweep(now); val l = live(a); l.handle.skip(a.str("entryId"), now); val r = pending(l); sweep(now); r } }
                "syncBatchFinish" -> { a.exact("handleId"); synchronized(lock) { handles.remove(a.str("handleId"))?.handle?.finish(); sweep(now) }; ChannelReply.Ok(null) }
                else -> ChannelReply.NotImplemented
            }
        } catch (e: SyncKeyFailure) { ChannelReply.Err(e.error.name) }
        catch (e: WireException) { ChannelReply.Err("WIRE_" + e.reason.substringBefore(':').uppercase().filter { it in 'A'..'Z' || it == '_' }) }
        catch (e: CustodyFailure) { ChannelReply.Err(e.error.name) }
        catch (_: Bad) { ChannelReply.Err("INVALID_INPUT") }
        catch (_: Exception) { ChannelReply.Err("UNAVAILABLE") } // anything unexpected: a bare code, never a message, never a crash across the channel; no purge
    }
}
