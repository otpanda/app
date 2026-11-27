package org.otpanda.totp

import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

// Native side of the seed-sync wire contract (API vector 7e2e6f9c, proof 99f136d3, seal 9032af4f). INACTIVE: pure JVM/JCA, no Android API, no network, nothing wired.
// Native BUILDS the signed bytes itself from its own state; callers pass only the server-checked values. Every field is validated with the server's own regexes
// before anything is signed or opened. Errors carry a reason code only, never a value, key or seed.
// Not covered here: the enrollment actionDigest bytes (accepted only as validated 64-hex input until the exact contract is supplied), and the ephemeral-handle
// lifecycle (begin/bind/consume/expire) that must gate [signBatchProof]; those belong to the unbuilt channel layer.

class WireException(val reason: String) : Exception(reason)
private fun bad(reason: String): Nothing = throw WireException(reason)

enum class SyncPurpose(val wire: String, val fields: List<String>) {
    ENROLL("seed-sync-enroll", listOf("ownerId", "keyId", "installId", "generation", "challenge", "actionDigest", "expiresAt")),
    SNAPSHOT("seed-sync-snapshot", listOf("ownerId", "keyId", "deviceId", "generation", "epoch", "challenge", "expiresAt")),
    REVOKE("seed-sync-revoke", listOf("ownerId", "keyId", "deviceId", "generation", "challenge", "expiresAt")),
    BATCH("seed-sync-batch", listOf("ownerId", "keyId", "deviceId", "generation", "epoch", "challenge", "ephemeralDigest", "entriesDigest", "expiresAt")),
    /** Key status without a bearer (revocation learned on reconnect). Deliberately carries NO owner, device, generation or epoch: only the key, the challenge and its expiry. */
    STATUS("seed-sync-status", listOf("keyId", "challenge", "expiresAt")),
}

/** Closed algorithm set, exactly the server's: wire names SHA-1, SHA-256, SHA-512 only. Anything else is refused, never mapped. */
fun wireAlgorithm(name: String): TotpCalculator.Algorithm = when (name) {
    "SHA-1" -> TotpCalculator.Algorithm.SHA1
    "SHA-256" -> TotpCalculator.Algorithm.SHA256
    "SHA-512" -> TotpCalculator.Algorithm.SHA512
    else -> bad("algorithm")
}

object SeedSyncWire {
    const val PROOF_LABEL = "otpanda-seed-sync-v1"
    const val SEAL_LABEL = "otpanda-seed-sync-seal-v1"
    const val PROOF_TTL_MS = 120_000L
    const val MAX_SAFE = 9_007_199_254_740_991L
    private val ID = Regex("[A-Za-z0-9_-]{1,128}")
    private val INSTALL = Regex("[A-Za-z0-9_-]{22,64}")
    private val CHALLENGE = Regex("[A-Za-z0-9_-]{43}")
    private val HEX64 = Regex("[a-f0-9]{64}")
    private val B64URL = Regex("[A-Za-z0-9_-]*")
    private val enc = Base64.getUrlEncoder().withoutPadding()

    fun b64(bytes: ByteArray): String = enc.encodeToString(bytes)
    /** Canonical unpadded base64url only: any padding, alphabet violation, wrong length or non-canonical trailing bits is refused. */
    fun unb64(s: String, expectedLen: Int? = null, maxLen: Int = 4096): ByteArray {
        if (s.length > maxLen * 2 || !B64URL.matches(s) || s.length % 4 == 1) bad("base64")
        val b = try { Base64.getUrlDecoder().decode(s) } catch (_: IllegalArgumentException) { bad("base64") }
        if (b64(b) != s) bad("base64")
        if (expectedLen != null && b.size != expectedLen) bad("length")
        return b
    }
    fun sha256Hex(b: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }
    fun challengeDigest(challenge: String): String { if (!CHALLENGE.matches(challenge)) bad("challenge"); return sha256Hex(challenge.toByteArray(Charsets.UTF_8)) }
    fun ephemeralDigest(raw: ByteArray): String { checkPoint(raw); return sha256Hex(raw) }

    /** sha256 hex of JSON.stringify([[entryId, seedVersion], ...]) sorted by entryId (plain string compare). Duplicates and bad ids are refused. */
    fun entriesDigest(entries: List<Pair<String, Long>>): String {
        for ((id, v) in entries) { if (!ID.matches(id) || v < 0 || v > MAX_SAFE) bad("entry") }
        if (entries.map { it.first }.toSet().size != entries.size) bad("entry")
        val sorted = entries.sortedWith { a, b -> a.first.compareTo(b.first) }
        return sha256Hex(sorted.joinToString(",", "[", "]") { "[\"${it.first}\",${it.second}]" }.toByteArray(Charsets.UTF_8))
    }

    private fun validate(name: String, v: Any?) {
        val ok = when (name) {
            "ownerId", "keyId", "deviceId" -> v is String && ID.matches(v)
            "installId" -> v is String && INSTALL.matches(v)
            "challenge" -> v is String && CHALLENGE.matches(v)
            "actionDigest", "ephemeralDigest", "entriesDigest" -> v is String && HEX64.matches(v)
            "generation", "epoch", "expiresAt" -> v is Long && v in 0..MAX_SAFE
            else -> false
        }
        if (!ok) bad("field:$name")
    }

    /** UTF-8 of the compact JSON array [label, purpose, ...fields in contract order]. [c] must hold exactly the purpose's fields. */
    fun proofMessage(purpose: SyncPurpose, c: Map<String, Any>): ByteArray {
        if (c.keys != purpose.fields.toSet()) bad("fields")
        purpose.fields.forEach { validate(it, c[it]) }
        val body = purpose.fields.joinToString(",") { f -> c.getValue(f).let { if (it is String) "\"$it\"" else it.toString() } }
        return "[\"$PROOF_LABEL\",\"${purpose.wire}\",$body]".toByteArray(Charsets.UTF_8)
    }

    /** Strict DER ECDSA-Sig-Value to fixed 64-byte r||s (P1363). Refuses long-form lengths, non-minimal or negative integers, zero, over-wide values, trailing bytes. */
    fun derToP1363(der: ByteArray): ByteArray {
        fun at(i: Int): Int { if (i >= der.size) bad("der"); return der[i].toInt() and 0xff }
        if (der.size < 8 || der.size > 72 || at(0) != 0x30 || at(1) != der.size - 2) bad("der")
        var i = 2
        fun int(): ByteArray {
            if (at(i) != 0x02) bad("der"); val len = at(i + 1); i += 2
            if (len < 1 || len > 33 || i + len > der.size) bad("der")
            val v = der.copyOfRange(i, i + len); i += len
            if (v[0].toInt() and 0x80 != 0) bad("der") // negative
            if (v.size > 1 && v[0] == 0.toByte() && v[1].toInt() and 0x80 == 0) bad("der") // non-minimal
            val stripped = if (v[0] == 0.toByte() && v.size > 1) v.copyOfRange(1, v.size) else v
            if (stripped.size > 32 || stripped.all { it == 0.toByte() }) bad("der")
            return ByteArray(32 - stripped.size) + stripped
        }
        val r = int(); val s = int()
        if (i != der.size) bad("der")
        return r + s
    }
    /** Inverse, for tests and for verifying server-format signatures with JCA. */
    fun p1363ToDer(sig: ByteArray): ByteArray {
        if (sig.size != 64) bad("sig")
        fun enc1(b: ByteArray): ByteArray { var s = b.dropWhile { it == 0.toByte() }.toByteArray(); if (s.isEmpty()) bad("sig"); if (s[0].toInt() and 0x80 != 0) s = byteArrayOf(0) + s; return byteArrayOf(2, s.size.toByte()) + s }
        val body = enc1(sig.copyOfRange(0, 32)) + enc1(sig.copyOfRange(32, 64))
        return byteArrayOf(0x30, body.size.toByte()) + body
    }

    /** Native-built proof signed with the dedicated seed-sync key of [owner]. [fields] holds ONLY values that come from outside: deviceId, challenge, expiresAt, and
     * (for snapshot, batch, revoke) the generation the server expects, plus the epoch the caller believes for snapshot and batch. ownerId, keyId and, for enroll,
     * installId are NATIVE (the durable enrollment record). Generation must EQUAL the enrollment's recorded generation, and epoch must EQUAL the owner's real native
     * epoch read from custody: a different value is refused before any signature. expiresAt must be in (now, now + 120 s]. Returns 86-char base64url P1363. */
    fun signProof(core: SeedSyncKeyCore, owner: String, purpose: SyncPurpose, fields: Map<String, Any>, nowMs: Long, expectKeyId: String? = null): String {
        val native = setOf("ownerId", "keyId", "installId")
        if (purpose == SyncPurpose.ENROLL) bad("purpose") // enroll goes through signEnrollProof only: its digest is recomputed there
        if (fields.keys != purpose.fields.toSet() - native) bad("fields")
        val exp = fields["expiresAt"]
        if (exp !is Long || nowMs < 0 || exp <= nowMs || exp > nowMs + PROOF_TTL_MS || exp > MAX_SAFE) bad("expiresAt")
        val der = core.signBuilt(owner) { ctx ->
            if (expectKeyId != null && ctx.keyId != expectKeyId) bad("key")
            if ("generation" in purpose.fields && fields["generation"] != ctx.generation) bad("generation")
            if ("epoch" in purpose.fields && fields["epoch"] != ctx.epoch) bad("epoch")
            proofMessage(purpose, fields + mapOf("keyId" to ctx.keyId) + (if ("ownerId" in purpose.fields) mapOf("ownerId" to owner) else emptyMap()))
        }
        return b64(derToP1363(der)).also { if (it.length != 86) bad("sig") }
    }

    /** The key id a status-begin request asks about: the owner's ACTIVE enrollment key, from native state (null when not enrolled, an erase is pending or owed, or the
     * state is unreadable: then there is nothing to ask, an erase is already running). Never taken from a caller. */
    fun statusKeyId(core: SeedSyncKeyCore, owner: String): String? = core.activeKeyIdFor(owner)

    /** Status proof for [challenge]. The key id is signed from native state and, when [expectKeyId] (the id the begin request used) is given, must still be the
     * active key, so a challenge issued for an older key is never signed by a newer one. */
    fun signStatusProof(core: SeedSyncKeyCore, owner: String, challenge: String, expiresAt: Long, nowMs: Long, expectKeyId: String): String =
        signProof(core, owner, SyncPurpose.STATUS, mapOf("challenge" to challenge, "expiresAt" to expiresAt), nowMs, expectKeyId)

    enum class StatusAction { KEEP, PURGE }
    /** Decision for the 200 body of status-finish. Only "key-revoked" and "generation-changed" purge; "active" keeps. Any other value is refused (never mapped).
     * A non-200 answer (the opaque 409, network error, rate limit) is not a state at all: the caller changes nothing and does not call this. */
    fun statusAction(state: String?): StatusAction = when (state) {
        "active" -> StatusAction.KEEP
        "key-revoked", "generation-changed" -> StatusAction.PURGE
        else -> bad("status")
    }
    private fun statusEraseTrigger(state: String?): EraseTrigger = when (state) {
        "key-revoked" -> EraseTrigger.REMOTE_KEY_REVOKED
        "generation-changed" -> EraseTrigger.GENERATION_CHANGED
        else -> bad("status")
    }

    enum class StatusOutcome { KEPT, PURGED, NOOP, PENDING, UNREADABLE }
    /** The only way to act on a status answer. [askedKeyId] is the key id the status-begin request used. An unknown [state] throws WireException("status") before
     * anything is read or changed (caller: change nothing, retry later). "active" keeps everything. A purge state erases ONLY if [askedKeyId] is still the active
     * key (core.eraseIfActive): a re-enrolled key, an already erased key gives NOOP (terminal, never retried); an erase intent, owed purge or unresolved key delete gives PENDING (retryPending owns it, no new request); an unreadable document gives UNREADABLE (nothing changed). A custody failure inside the erase is rethrown after the
     * deny-first steps as for any erase, and retryPending continues it. */
    fun applyStatus(core: SeedSyncKeyCore, owner: String, askedKeyId: String, state: String?): StatusOutcome {
        val trigger = when (statusAction(state)) { StatusAction.KEEP -> return StatusOutcome.KEPT; StatusAction.PURGE -> statusEraseTrigger(state) }
        return when (core.eraseIfActive(owner, askedKeyId, trigger)) {
            SeedSyncKeyCore.StatusErase.ERASED -> StatusOutcome.PURGED
            SeedSyncKeyCore.StatusErase.SUPERSEDED -> StatusOutcome.NOOP
            SeedSyncKeyCore.StatusErase.PENDING -> StatusOutcome.PENDING
            SeedSyncKeyCore.StatusErase.UNREADABLE -> StatusOutcome.UNREADABLE
        }
    }

    /** Batch proof with ephemeralDigest and entriesDigest computed here from the native handle and the exact requested entry set. */
    fun signBatchProof(core: SeedSyncKeyCore, owner: String, deviceId: String, generation: Long, epoch: Long, challenge: String, expiresAt: Long,
                       ephemeralRaw: ByteArray, entries: List<Pair<String, Long>>, nowMs: Long, expectKeyId: String? = null): String =
        signProof(core, owner, SyncPurpose.BATCH, mapOf("deviceId" to deviceId, "generation" to generation, "epoch" to epoch, "challenge" to challenge,
            "ephemeralDigest" to ephemeralDigest(ephemeralRaw), "entriesDigest" to entriesDigest(entries), "expiresAt" to expiresAt), nowMs, expectKeyId)

    /** lowercase hex sha256 of UTF-8 JSON.stringify(["seed-sync-enroll-v1", ownerId, installId, keyText, generation]) where keyText is the JSON text
     * {"kty":"EC","crv":"P-256","x":..,"y":..} (that order, unpadded base64url coordinates) embedded as an escaped JSON string. Computed from the NEW key's own public point. */
    fun enrollActionDigest(ownerId: String, installId: String, publicRaw: ByteArray, generation: Long): String {
        if (!ID.matches(ownerId) || !INSTALL.matches(installId) || generation !in 0..MAX_SAFE) bad("action")
        checkPoint(publicRaw)
        val keyText = "{\"kty\":\"EC\",\"crv\":\"P-256\",\"x\":\"${b64(publicRaw.copyOfRange(1, 33))}\",\"y\":\"${b64(publicRaw.copyOfRange(33, 65))}\"}"
        val preimage = "[\"seed-sync-enroll-v1\",\"$ownerId\",\"$installId\",\"${keyText.replace("\"", "\\\"")}\",$generation]"
        return sha256Hex(preimage.toByteArray(Charsets.UTF_8))
    }

    /** Enrollment proof. installId and generation come from the durable enrollment record, never from a caller. The action digest is recomputed here from the new
     * key's own public point and those recorded values, and must equal the server's challenge value: never blind-accepted. [enrollment] must be the enrollment of the
     * key that actually signs. */
    fun signEnrollProof(core: SeedSyncKeyCore, owner: String, enrollment: Enrollment, challenge: String, serverActionDigest: String, expiresAt: Long, nowMs: Long): String {
        if (nowMs < 0 || expiresAt <= nowMs || expiresAt > nowMs + PROOF_TTL_MS || expiresAt > MAX_SAFE) bad("expiresAt")
        val der = core.signBuilt(owner) { ctx ->
            if (ctx.keyId != enrollment.keyId) bad("key")
            if (enrollActionDigest(owner, ctx.installId, enrollment.publicKey, ctx.generation) != serverActionDigest) bad("actionDigest")
            proofMessage(SyncPurpose.ENROLL, mapOf("ownerId" to owner, "keyId" to ctx.keyId, "installId" to ctx.installId, "generation" to ctx.generation, "challenge" to challenge,
                "actionDigest" to serverActionDigest, "expiresAt" to expiresAt))
        }
        return b64(derToP1363(der))
    }

    // ---- P-256 point validation and sealing ----
    private val P = BigInteger("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff", 16)
    private val B = BigInteger("5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b", 16)
    private val params: ECParameterSpec by lazy { AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }.getParameterSpec(ECParameterSpec::class.java) }

    /** Raw uncompressed P-256 point: 65 bytes, 0x04 prefix, coordinates below p, on the curve. */
    fun checkPoint(raw: ByteArray) {
        if (raw.size != 65 || raw[0] != 4.toByte()) bad("point")
        val x = BigInteger(1, raw.copyOfRange(1, 33)); val y = BigInteger(1, raw.copyOfRange(33, 65))
        if (x >= P || y >= P) bad("point")
        if (y.multiply(y).mod(P) != x.pow(3).subtract(x.multiply(BigInteger.valueOf(3))).add(B).mod(P)) bad("point")
    }
    private fun publicKey(raw: ByteArray): java.security.PublicKey {
        checkPoint(raw)
        return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(BigInteger(1, raw.copyOfRange(1, 33)), BigInteger(1, raw.copyOfRange(33, 65))), params))
    }

    /** One-use device ephemeral P-256 key, memory only. The private key never leaves this object except to [openSealed]. */
    class Ephemeral private constructor(internal val private: PrivateKey, val raw: ByteArray) {
        val digest: String get() = sha256Hex(raw)
        companion object {
            fun generate(): Ephemeral {
                val g = KeyPairGenerator.getInstance("EC"); g.initialize(ECGenParameterSpec("secp256r1"))
                val kp = g.generateKeyPair()
                val w = (kp.public as ECPublicKey).w
                fun fix(b: BigInteger) = b.toByteArray().let { if (it.size > 32) it.copyOfRange(it.size - 32, it.size) else ByteArray(32 - it.size) + it }
                return Ephemeral(kp.private, byteArrayOf(4) + fix(w.affineX) + fix(w.affineY)).also { checkPoint(it.raw) }
            }
            internal fun of(private: PrivateKey, raw: ByteArray) = Ephemeral(private, raw)
        }
    }

    /** What the device knows about an entry from its OWN request and ticket (never from the response): this is the AAD source. */
    data class SealContext(val ownerId: String, val deviceId: String, val epoch: Long, val entryId: String, val seedVersion: Long,
                           val algorithm: String, val digits: Int, val period: Int, val challenge: String)

    /** AAD = UTF-8 compact JSON [label, ownerId, deviceId, epoch, entryId, seedVersion, algorithm, digits, period, challengeDigest, ephemeralDigest]. */
    fun sealAad(c: SealContext, ephemeralDigest: String): ByteArray {
        if (!ID.matches(c.ownerId) || !ID.matches(c.deviceId) || !ID.matches(c.entryId)) bad("aad")
        if (c.epoch !in 0..MAX_SAFE || c.seedVersion !in 0..MAX_SAFE || c.digits !in 6..8 || c.period !in 1..86_400 || !HEX64.matches(ephemeralDigest)) bad("aad")
        wireAlgorithm(c.algorithm)
        return ("[\"$SEAL_LABEL\",\"${c.ownerId}\",\"${c.deviceId}\",${c.epoch},\"${c.entryId}\",${c.seedVersion},\"${c.algorithm}\",${c.digits},${c.period}," +
            "\"${challengeDigest(c.challenge)}\",\"$ephemeralDigest\"]").toByteArray(Charsets.UTF_8)
    }

    private fun hmac(key: ByteArray, data: ByteArray): ByteArray = Mac.getInstance("HmacSHA256").run { init(SecretKeySpec(key, "HmacSHA256")); doFinal(data) }
    /** HKDF-SHA256 (RFC 5869) written out with HMAC, one output block (32 bytes): no dependence on a platform HKDF. */
    fun hkdf32(ikm: ByteArray, salt: ByteArray, info: ByteArray): ByteArray = hmac(hmac(salt, ikm), info + byteArrayOf(1))

    /** Opens one sealed entry. Seed length must be 10..128 bytes. The caller zeroes the returned array after provisioning. Any failure throws WireException with a
     * reason code only; AES-GCM tag failure is "open". */
    fun openSealed(eph: Ephemeral, ctx: SealContext, serverPublicKey: String, nonce: String, ciphertext: String): ByteArray {
        val serverRaw = unb64(serverPublicKey, 65)
        val aad = sealAad(ctx, eph.digest)
        val n = unb64(nonce, 12)
        val ct = unb64(ciphertext, maxLen = 16 + 128)
        if (ct.size < 16 + 10 || ct.size > 16 + 128) bad("length")
        val ka = KeyAgreement.getInstance("ECDH"); ka.init(eph.private); ka.doPhase(publicKey(serverRaw), true)
        val shared = ka.generateSecret(); if (shared.size != 32) bad("ecdh")
        val key = hkdf32(shared, hexBytes(challengeDigest(ctx.challenge)), "$SEAL_LABEL|${eph.digest}|${sha256Hex(serverRaw)}".toByteArray(Charsets.UTF_8))
        return try {
            Cipher.getInstance("AES/GCM/NoPadding").run { init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, n)); updateAAD(aad); doFinal(ct) }
        } catch (_: java.security.GeneralSecurityException) { bad("open") } finally { key.fill(0); shared.fill(0) }
    }
    private fun hexBytes(h: String) = ByteArray(h.length / 2) { h.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    internal fun jcaParams() = params
}
