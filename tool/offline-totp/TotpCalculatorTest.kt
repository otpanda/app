package org.otpanda.totp

import javax.crypto.spec.SecretKeySpec
import javax.crypto.Mac
import javax.crypto.MacSpi
import java.security.Provider
import java.security.Security
import java.security.Key
import java.security.spec.AlgorithmParameterSpec

class HandleKey : javax.crypto.SecretKey {
    var reads = 0
    override fun getAlgorithm() = "HmacSHA1"
    override fun getFormat(): String? = null
    override fun getEncoded(): ByteArray { reads++; error("No raw bytes") }
}
class HandleMac : MacSpi() {
    private var inner: Mac? = null
    override fun engineGetMacLength() = 20
    override fun engineInit(key: Key, parameters: AlgorithmParameterSpec?) {
        require(key is HandleKey && parameters == null)
        inner = Mac.getInstance("HmacSHA1", "SunJCE").also {
            it.init(SecretKeySpec("12345678901234567890".toByteArray(), "HmacSHA1"))
        }
    }
    override fun engineUpdate(input: Byte) { inner!!.update(input) }
    override fun engineUpdate(input: ByteArray, offset: Int, len: Int) { inner!!.update(input, offset, len) }
    override fun engineDoFinal(): ByteArray = inner!!.doFinal()
    override fun engineReset() { inner?.reset() }
}
class HandleProvider : Provider("OTPandaSyntheticHandle", "1.0", "Synthetic handle test only") {
    init { put("Mac.HmacSHA1", HandleMac::class.java.name) }
}

fun main() {
    val times = listOf(59L, 1111111109L, 1111111111L, 1234567890L, 2000000000L, 20000000000L)
    val seeds = listOf("12345678901234567890", "12345678901234567890123456789012",
        "1234567890123456789012345678901234567890123456789012345678901234")
    val expected = listOf(
        listOf("94287082", "07081804", "14050471", "89005924", "69279037", "65353130"),
        listOf("46119246", "68084774", "67062674", "91819424", "90698825", "77737706"),
        listOf("90693936", "25091201", "99943326", "93441116", "38618901", "47863826"))
    for ((a, algorithm) in TotpCalculator.Algorithm.entries.withIndex()) {
        val key = SecretKeySpec(seeds[a].toByteArray(Charsets.US_ASCII), algorithm.jcaName)
        for ((i, time) in times.withIndex()) {
            val value = TotpCalculator.generate(key, time, algorithm, digits = 8)
            check(value.code == expected[a][i]) { "RFC vector failed" }
            check(value.validFromSeconds == time / 30 * 30)
            check(value.validUntilSeconds == time / 30 * 30 + 30)
        }
    }
    val key = SecretKeySpec(seeds[0].toByteArray(), "HmacSHA1")
    check(TotpCalculator.generate(key, 59, TotpCalculator.Algorithm.SHA1).code == "287082")
    check(TotpCalculator.generate(key, 30, TotpCalculator.Algorithm.SHA1).code == TotpCalculator.generate(key, 59, TotpCalculator.Algorithm.SHA1).code)
    check(TotpCalculator.generate(key, 60, TotpCalculator.Algorithm.SHA1).code != TotpCalculator.generate(key, 59, TotpCalculator.Algorithm.SHA1).code)
    check(TotpCalculator.generate(key, 59, TotpCalculator.Algorithm.SHA1, periodSeconds = 60).validUntilSeconds == 60L)
    check(TotpCalculator.generate(key, 59, TotpCalculator.Algorithm.SHA1, digits = 7).code == "4287082")
    fun reject(work: () -> Unit) { check(runCatching(work).isFailure) }
    reject { TotpCalculator.generate(key, -1, TotpCalculator.Algorithm.SHA1) }
    reject { TotpCalculator.generate(key, Long.MAX_VALUE, TotpCalculator.Algorithm.SHA1) }
    reject { TotpCalculator.generate(key, 59, TotpCalculator.Algorithm.SHA1, digits = 5) }
    reject { TotpCalculator.generate(key, 59, TotpCalculator.Algorithm.SHA1, digits = 9) }
    reject { TotpCalculator.generate(key, 59, TotpCalculator.Algorithm.SHA1, periodSeconds = 0) }
    reject { TotpCalculator.generate(key, 59, TotpCalculator.Algorithm.SHA1, periodSeconds = -30) }
    // A provider/key failure must not trigger byte extraction or another store.
    val nonexportable = object : javax.crypto.SecretKey {
        override fun getAlgorithm() = "HmacSHA1"
        override fun getFormat(): String? = null
        override fun getEncoded(): ByteArray = error("Must not export key")
    }
    reject { TotpCalculator.generate(nonexportable, 59, TotpCalculator.Algorithm.SHA1) }
    val provider = HandleProvider()
    Security.insertProviderAt(provider, 1)
    try {
        val handle = HandleKey()
        check(TotpCalculator.generate(handle, 59, TotpCalculator.Algorithm.SHA1, digits = 8).code == "94287082")
        check(handle.reads == 0) { "Calculator tried to extract the key" }
    } finally { Security.removeProvider(provider.name) }
    println("PASS RFC6238 all18 vectors, boundaries, digits, periods, 64-bit time and fail-closed key rejection; no device/storage proof")
}
