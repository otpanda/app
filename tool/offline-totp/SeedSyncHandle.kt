package org.otpanda.totp

// One seed-sync download batch on the device (design v4 section 3, reviewer pins). INACTIVE: pure JVM, no channel, no network, nothing wired.
// A handle is single use and moves strictly NEW -> BOUND -> SIGNED -> DONE. It owns one ephemeral P-256 key, the exact entry set the device asked for (from its
// own signed snapshot, never from the response), and the server challenge. Every entry is consumed on its first attempt, successful or not. The seed exists only
// inside [open]'s callback and is zeroed on every path, including when the callback throws. Any failure that burns the challenge discards the whole handle.
// maxEntries defaults to 3, the server's maxBatch, which is still pending CPU qualification: it is a knob, not a verified limit.
// Not covered: the platform key objects cannot be erased from memory (JCA offers no zeroing for PrivateKey); the handle only drops its references.

/** What the device itself knows about an entry from its own validated snapshot. */
data class SealedEntrySpec(val entryId: String, val seedVersion: Long, val algorithm: String, val digits: Int, val period: Int)

class SeedSyncBatchHandle private constructor(
    private val core: SeedSyncKeyCore,
    private val owner: String,
    private val deviceId: String,
    private val generation: Long,
    private val epoch: Long,
    private val keyId: String,
    private val eph: SeedSyncWire.Ephemeral,
    specs: List<SealedEntrySpec>,
) {
    enum class State { NEW, BOUND, SIGNED, DONE, DISCARDED }

    private val lock = Any()
    private val entries: Map<String, SealedEntrySpec> = specs.associateBy { it.entryId }
    private val pending = LinkedHashSet(entries.keys)
    private var challenge: String? = null
    private var expiresAt = 0L
    private var boundAt = 0L
    private var localDeadline = 0L
    private var pinnedServerKey: String? = null
    var state = State.NEW; private set
    /** TEST ONLY: runs between decrypt and the guarded provision step. Never set in production (release guard). */
    internal var testHookBeforeGuard: (() -> Unit)? = null

    private fun bad(r: String): Nothing = throw WireException(r)
    private fun need(s: State) { if (state != s) { discard(); bad("state") } }

    /** The public half of the ephemeral key, canonical base64url (what the batch request sends). Public data only. */
    fun ephemeralPublic(): String = SeedSyncWire.b64(eph.raw)

    /** Entries not yet consumed. */
    fun pendingEntries(): Set<String> = synchronized(lock) { pending.toSet() }

    /** Records the server challenge and its server-owned expiry. One attempt: any failure discards the handle. */
    fun bind(challenge: String, expiresAt: Long, nowMs: Long) = synchronized(lock) {
        need(State.NEW)
        try {
            SeedSyncWire.challengeDigest(challenge)
            if (nowMs < 0 || expiresAt <= nowMs || expiresAt > nowMs + SeedSyncWire.PROOF_MAX_AHEAD_MS || expiresAt > SeedSyncWire.MAX_SAFE) bad("expiresAt")
        } catch (e: WireException) { discard(); throw e }
        this.challenge = challenge; this.expiresAt = expiresAt
        boundAt = nowMs
        // A behind clock may accept a later absolute server expiry, but cannot keep
        // an ephemeral batch alive longer than 120 seconds after local receipt.
        localDeadline = minOf(expiresAt, nowMs + SeedSyncWire.PROOF_TTL_MS)
        state = State.BOUND
    }

    /** Signs the batch proof once. The entries digest and ephemeral digest come from this handle, the key must still be the one the handle began with, and epoch and
     * generation are checked against native state. After this call the challenge is considered used whatever happens: a failure discards the handle. */
    fun signProof(nowMs: Long): String = synchronized(lock) {
        need(State.BOUND)
        if (nowMs < boundAt || nowMs >= localDeadline) { discard(); bad("expired") }
        state = State.SIGNED // single use: a second attempt, or a retry after a failed signature, is refused
        try {
            SeedSyncWire.signBatchProof(core, owner, deviceId, generation, epoch, challenge!!, expiresAt, eph.raw, entries.values.map { it.entryId to it.seedVersion }, nowMs, keyId)
        } catch (e: Exception) { discard(); throw e }
    }

    /** Consumes an entry the server did not seal (stale, removed, unsupported). Never opens anything. */
    fun skip(entryId: String, nowMs: Long) = synchronized(lock) { consume(entryId, nowMs); finishIfEmpty() }

    /** Opens one sealed entry and hands the seed to [provision], then zeroes it. The entry is consumed before anything is decrypted, so a retry of the same entry
     * is refused. The server public key must be the same for every entry of the batch. Nothing is provisioned unless the enrollment key is still active and no
     * erase is pending or owed, checked atomically with [provision] under the core lock. [provision] MUST copy the seed synchronously if it keeps it (the array is
     * zeroed when it returns, also when it throws) and must not call back into the core. A failure of the opening discards the handle (remaining entries are not opened). */
    fun open(entryId: String, serverPublicKey: String, nonce: String, ciphertext: String, nowMs: Long, provision: (SealedEntrySpec, ByteArray) -> Unit) = synchronized(lock) {
        val spec = consume(entryId, nowMs)
        var seed: ByteArray? = null
        try {
            val pinned = pinnedServerKey
            if (pinned != null && pinned != serverPublicKey) bad("serverKey")
            val ctx = SeedSyncWire.SealContext(owner, deviceId, epoch, spec.entryId, spec.seedVersion, spec.algorithm, spec.digits, spec.period, challenge!!)
            seed = SeedSyncWire.openSealed(eph, ctx, serverPublicKey, nonce, ciphertext)
            pinnedServerKey = serverPublicKey
            testHookBeforeGuard?.invoke()
            // The checks and the callback run under ONE core lock (see runIfActive): an erase cannot land between them. "epoch" and "inactive" are refusals, never a
            // reason to purge; on "epoch" (also clock skew or a stale batch) the caller starts a fresh batch.
            val s = seed!!
            val refusal = core.runIfActive(owner, keyId, epoch) { provision(spec, s) }
            if (refusal != null) bad(refusal)
        } catch (e: Throwable) { discard(); throw e } finally { seed?.fill(0) }
        finishIfEmpty()
    }

    private fun consume(entryId: String, nowMs: Long): SealedEntrySpec {
        need(State.SIGNED)
        if (nowMs < boundAt || nowMs >= localDeadline) { discard(); bad("expired") }
        val spec = entries[entryId]
        if (spec == null || !pending.remove(entryId)) { discard(); bad("entry") } // unknown or already consumed: the response does not match the request
        return spec
    }
    private fun finishIfEmpty() { if (pending.isEmpty() && state == State.SIGNED) { state = State.DONE; drop() } }

    /** Callers must call this (finally) once the response is processed: if the server sealed fewer entries than requested and some were neither opened nor
     * skipped, the handle would otherwise keep the ephemeral key until dropped. After it the handle is DONE or DISCARDED and holds nothing. */
    fun finish() = discard()

    /** Drops the ephemeral key reference and every pending entry. Safe to call at any time and more than once. */
    fun discard() { synchronized(lock) { if (state != State.DONE) state = State.DISCARDED; pending.clear(); drop() } }
    private fun drop() { challenge = null; pinnedServerKey = null }

    companion object {
        const val DEFAULT_MAX_ENTRIES = 3

        /** Starts a batch for exactly [specs] (from the device's own snapshot). generation and epoch are checked against native state at signing time. */
        fun begin(core: SeedSyncKeyCore, owner: String, deviceId: String, generation: Long, epoch: Long, specs: List<SealedEntrySpec>, maxEntries: Int = DEFAULT_MAX_ENTRIES): SeedSyncBatchHandle {
            if (specs.isEmpty() || specs.size > minOf(maxEntries, DEFAULT_MAX_ENTRIES) || specs.map { it.entryId }.toSet().size != specs.size) throw WireException("entries")
            val probe = SeedSyncWire.Ephemeral.generate()
            for (s in specs) SeedSyncWire.sealAad(SeedSyncWire.SealContext(owner, deviceId, epoch, s.entryId, s.seedVersion, s.algorithm, s.digits, s.period, "A".repeat(43)), probe.digest)
            SeedSyncWire.entriesDigest(specs.map { it.entryId to it.seedVersion })
            val keyId = core.activeKeyIdFor(owner) ?: throw WireException("not-enrolled")
            return SeedSyncBatchHandle(core, owner, deviceId, generation, epoch, keyId, probe, specs)
        }
    }
}
