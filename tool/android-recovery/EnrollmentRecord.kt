package org.otpanda.recovery

import java.security.MessageDigest

/** Nonsecret binding only, never sufficient to authenticate. Store under
 * Context.noBackupFilesDir; not cache, shared preferences or external storage.
 */
data class EnrollmentRecord(val ownerId: String, val keyId: String, val publicKeyHash: String) {
    fun encode(): String {
        require(listOf(ownerId,keyId).all { it.matches(Regex("[A-Za-z0-9_-]{1,128}")) })
        require(publicKeyHash.matches(Regex("[a-f0-9]{64}")))
        return "otpanda-enrolled-device-v1\n$ownerId\n$keyId\n$publicKeyHash\n"
    }
    fun matchesPublicKey(spki: ByteArray) = publicKeyHash == hash(spki)
    companion object {
        fun hash(spki: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(spki).joinToString("") { "%02x".format(it) }
        fun decode(text: String): EnrollmentRecord {
            require(text.length <= 400)
            val parts=text.split('\n')
            require(parts.size==5 && parts[0]=="otpanda-enrolled-device-v1" && parts[4].isEmpty())
            return EnrollmentRecord(parts[1],parts[2],parts[3]).also { require(it.encode()==text) }
        }
    }
}

/** Fail closed on missing, malformed or mismatched key/metadata. No reenroll. */
fun enrolledState(record: EnrollmentRecord?, publicSpki: ByteArray?): String = when {
    record == null && publicSpki == null -> "not-enrolled"
    record == null -> "unconfirmed-local-key"
    publicSpki == null -> "enrolled-key-unavailable"
    !record.matchesPublicKey(publicSpki) -> "enrolled-key-mismatch"
    else -> "enrolled-unverified-platform-policy"
}

/** Pure preflight before any key creation or server enrollment request. */
fun validateEnrollmentCandidate(record: EnrollmentRecord?, publicSpki: ByteArray?) {
    check(record == null || publicSpki != null) { "Confirmed metadata without key; use another method" }
    if (record != null) check(record.matchesPublicKey(publicSpki!!)) { "Key mismatch" }
}
