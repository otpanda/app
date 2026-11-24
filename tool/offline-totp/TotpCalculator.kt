package org.otpanda.totp

import javax.crypto.Mac
import javax.crypto.SecretKey

/** Pure calculator. Never reads raw key bytes, persists keys, or fetches codes. */
object TotpCalculator {
    enum class Algorithm(val jcaName: String) {
        SHA1("HmacSHA1"), SHA256("HmacSHA256"), SHA512("HmacSHA512")
    }
    data class Value(val code: String, val validFromSeconds: Long, val validUntilSeconds: Long)

    fun generate(key: SecretKey, unixSeconds: Long, algorithm: Algorithm,
                 digits: Int = 6, periodSeconds: Int = 30): Value {
        require(unixSeconds >= 0) { "Nonnegative explicit Unix time required" }
        require(digits in 6..8) { "Digits must be 6 through 8" }
        require(periodSeconds > 0) { "Positive period required" }
        val step = unixSeconds / periodSeconds
        val from = step * periodSeconds
        require(from <= Long.MAX_VALUE - periodSeconds) { "Period end overflow" }
        val counter = ByteArray(8) { index -> (step ushr ((7 - index) * 8)).toByte() }
        // Let JCA select a provider that accepts this key handle. Do not pin a
        // software provider or fall back to key.encoded when a key is rejected.
        val mac = Mac.getInstance(algorithm.jcaName)
        mac.init(key)
        val digest = mac.doFinal(counter)
        try {
            val offset = digest.last().toInt() and 15
            val binary = ((digest[offset].toInt() and 127) shl 24) or
                ((digest[offset + 1].toInt() and 255) shl 16) or
                ((digest[offset + 2].toInt() and 255) shl 8) or
                (digest[offset + 3].toInt() and 255)
            val modulus = when (digits) { 6 -> 1_000_000; 7 -> 10_000_000; else -> 100_000_000 }
            return Value((binary % modulus).toString().padStart(digits, '0'), from, from + periodSeconds)
        } finally {
            counter.fill(0)
            digest.fill(0)
        }
    }
}
