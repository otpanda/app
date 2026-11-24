package org.otpanda.recovery

/** Matches the server's deviceProofMessage, not a free-form signing API. */
data class DeviceProof(
    val purpose: String, val ownerId: String, val keyId: String,
    val generation: Long, val challenge: String, val actionDigest: String,
    val expiresAt: Long,
) {
    fun message(now: Long): ByteArray {
        require(now in 0..9007199254740991L && expiresAt <= 9007199254740991L && expiresAt > now)
        require(purpose in setOf("enroll", "step-up", "recover-access"))
        require(listOf(ownerId, keyId).all { it.matches(Regex("[A-Za-z0-9_-]{1,128}")) })
        require(generation in 0..9007199254740991L)
        require(challenge.matches(Regex("[A-Za-z0-9_-]{43}")))
        require(actionDigest.matches(Regex("[a-f0-9]{64}")))
        return "[\"otpanda-device-proof-v1\",\"$purpose\",\"$ownerId\",\"$keyId\",$generation,\"$challenge\",\"$actionDigest\",$expiresAt]".toByteArray(Charsets.UTF_8)
    }
}

/** Strict DER ECDSA to the server's exactly64byte P1363 representation. */
fun derToP1363(der: ByteArray): ByteArray {
    require(der.size in 8..72 && der[0].toInt() == 0x30 && (der[1].toInt() and 255) == der.size - 2)
    var offset = 2
    fun integer(): ByteArray {
        require(offset + 2 <= der.size && der[offset++].toInt() == 2)
        val size = der[offset++].toInt() and 255
        require(size in 1..33 && offset + size <= der.size)
        val start = offset
        require((der[start].toInt() and 128) == 0)
        if (size > 1 && der[start].toInt() == 0) require((der[start+1].toInt() and 128) != 0)
        val skip = if (size == 33) 1 else 0
        if (skip == 1) require(der[start].toInt() == 0)
        val result = ByteArray(32)
        der.copyInto(result,32-(size-skip),start+skip,start+size)
        offset += size
        require(result.any { it.toInt() != 0 })
        return result
    }
    val r = integer(); val s = integer(); require(offset == der.size)
    return r + s
}
