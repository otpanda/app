package org.otpanda.totp

import javax.crypto.SecretKey
import javax.crypto.spec.SecretKeySpec

// JVM tests of custody logic with an in-memory SOFTWARE fake vault. They prove metadata/ordering/fail-closed behavior, not Android Keystore,
// hardware, uninstall, backup or OS invalidation behavior. Only published RFC 6238 synthetic seeds are used.
class FakeVault : KeyVault {
    val keys = HashMap<String, SecretKeySpec>()
    var hardware = true
    var failImport = false
    var maxSeed = 1000
    var keyError: VaultException.Kind? = null
    var wrongAlgorithm = false
    val deleted = ArrayList<String>()
    override fun containsAlias(alias: String) = alias in keys
    override fun aliases(): Set<String> = keys.keys.toSet()
    override fun importSeed(alias: String, seed: ByteArray, algorithm: TotpCalculator.Algorithm): ProtectionReport {
        if (seed.size > maxSeed) throw VaultException(VaultException.Kind.UNSUPPORTED_SEED, "size")
        if (failImport) { keys[alias] = SecretKeySpec(seed.copyOf(), algorithm.jcaName); throw VaultException(VaultException.Kind.UNAVAILABLE, "boom") }
        keys[alias] = SecretKeySpec(seed.copyOf(), algorithm.jcaName)
        return ProtectionReport(hardware, if (hardware) "secure_hardware" else "software")
    }
    override fun key(alias: String): SecretKey? {
        keyError?.let { throw VaultException(it, "fake") }
        val key = keys[alias] ?: return null
        return if (wrongAlgorithm) SecretKeySpec(key.encoded, "HmacSHA512") else key
    }
    override fun delete(alias: String) { deleted.add(alias); keys.remove(alias) }
}
class FakeStore : RecordStore {
    val map = HashMap<String, SeedRecord>()
    var failWrite = false
    var hideRecordsFromList = false
    override fun read(accountId: String) = map[accountId]
    override fun accountIds(): Set<String> = map.keys.toSet()
    override fun write(record: SeedRecord) { if (failWrite) error("disk full"); check(record.accountId !in map); map[record.accountId] = record }
    override fun delete(accountId: String) { map.remove(accountId) }
}

private fun reject(work: () -> Unit) { check(runCatching(work).isFailure) { "expected failure" } }
private fun seed(a: TotpCalculator.Algorithm) = when (a) {
    TotpCalculator.Algorithm.SHA1 -> "12345678901234567890"
    TotpCalculator.Algorithm.SHA256 -> "12345678901234567890123456789012"
    TotpCalculator.Algorithm.SHA512 -> "1234567890123456789012345678901234567890123456789012345678901234"
}.toByteArray(Charsets.US_ASCII)

fun main() {
    // Provision then generate: RFC 6238 8-digit vectors at T=59 for all three algorithms; digits/period come only from the record.
    val expected59 = mapOf(TotpCalculator.Algorithm.SHA1 to "94287082", TotpCalculator.Algorithm.SHA256 to "46119246", TotpCalculator.Algorithm.SHA512 to "90693936")
    for (algorithm in TotpCalculator.Algorithm.entries) {
        val vault = FakeVault(); val store = FakeStore(); val custody = LocalSeedCustody(vault, store)
        val input = seed(algorithm)
        custody.provision("acct_1", input, algorithm, 8, 30, 1_800_000_000)
        check(input.all { it == 0.toByte() }) { "seed must be zeroed" }
        val result = custody.generate("acct_1", 59)
        check(result is CodeResult.Code && result.value.code == expected59[algorithm]) { "vector $algorithm" }
        check(store.map["acct_1"]!!.protection == "secure_hardware" && store.map["acct_1"]!!.algorithm == algorithm)
        check(custody.accounts().keys == setOf("acct_1"))
    }
    // Create-only: a second provision (record or key present) fails and changes nothing; rotation is explicit delete then provision.
    run {
        val vault = FakeVault(); val store = FakeStore(); val custody = LocalSeedCustody(vault, store)
        custody.provision("a", seed(TotpCalculator.Algorithm.SHA1), TotpCalculator.Algorithm.SHA1, 6, 30, 1)
        val before = store.map["a"]
        reject { custody.provision("a", seed(TotpCalculator.Algorithm.SHA256), TotpCalculator.Algorithm.SHA256, 8, 60, 2) }
        check(store.map["a"] == before && vault.keys["a".let { SeedRecord.aliasFor(it) }]!!.algorithm == "HmacSHA1")
        custody.delete("a")
        check(store.map.isEmpty() && vault.keys.isEmpty())
        custody.provision("a", seed(TotpCalculator.Algorithm.SHA256), TotpCalculator.Algorithm.SHA256, 8, 60, 2)
        check(store.map["a"]!!.periodSeconds == 60)
    }
    // Input validation and zeroing on failure paths.
    run {
        val vault = FakeVault(); val store = FakeStore(); val custody = LocalSeedCustody(vault, store)
        val bad = ByteArray(5) { 1 }
        reject { custody.provision("a", bad, TotpCalculator.Algorithm.SHA1, 6, 30, 1) }
        check(bad.all { it == 0.toByte() })
        reject { custody.provision("a", ByteArray(129) { 1 }, TotpCalculator.Algorithm.SHA1, 6, 30, 1) }
        reject { custody.provision("a b", seed(TotpCalculator.Algorithm.SHA1), TotpCalculator.Algorithm.SHA1, 6, 30, 1) }
        reject { custody.provision("../x", seed(TotpCalculator.Algorithm.SHA1), TotpCalculator.Algorithm.SHA1, 6, 30, 1) }
        reject { custody.provision("a", seed(TotpCalculator.Algorithm.SHA1), TotpCalculator.Algorithm.SHA1, 9, 30, 1) }
        reject { custody.provision("a", seed(TotpCalculator.Algorithm.SHA1), TotpCalculator.Algorithm.SHA1, 6, 0, 1) }
        check(store.map.isEmpty() && vault.keys.isEmpty())
    }
    // Weak protection is refused by default and rolled back; an explicit opt-out records the level honestly.
    run {
        val vault = FakeVault().apply { hardware = false }; val store = FakeStore()
        reject { LocalSeedCustody(vault, store).provision("a", seed(TotpCalculator.Algorithm.SHA1), TotpCalculator.Algorithm.SHA1, 6, 30, 1) }
        check(store.map.isEmpty() && vault.keys.isEmpty()) { "weak key rolled back" }
        LocalSeedCustody(vault, store, allowSoftwareKeysForTests = true).provision("a", seed(TotpCalculator.Algorithm.SHA1), TotpCalculator.Algorithm.SHA1, 6, 30, 1)
        check(store.map["a"]!!.protection == "software")
    }
    // Seeds the platform rejects by size fail with a distinct reason and leave nothing behind (limits on real Keystore are unproven).
    run {
        val vault = FakeVault().apply { maxSeed = 64 }; val store = FakeStore(); val custody = LocalSeedCustody(vault, store)
        custody.provision("a", ByteArray(64) { 1 }, TotpCalculator.Algorithm.SHA1, 6, 30, 1)
        val e = runCatching { custody.provision("b", ByteArray(65) { 1 }, TotpCalculator.Algorithm.SHA512, 6, 30, 1) }.exceptionOrNull() as CustodyException
        check(e.reason == "vault_unsupported_seed") { e.reason }
        check(store.map.keys == setOf("a") && vault.keys.size == 1)
    }
    // Orphan key without a record is cleaned and provision proceeds; a real record is never replaced.
    run {
        val vault = FakeVault(); val store = FakeStore(); val custody = LocalSeedCustody(vault, store)
        vault.keys[SeedRecord.aliasFor("a")] = SecretKeySpec(ByteArray(20) { 9 }, "HmacSHA1")
        custody.provision("a", seed(TotpCalculator.Algorithm.SHA1), TotpCalculator.Algorithm.SHA1, 8, 30, 1)
        check((custody.generate("a", 59) as CodeResult.Code).value.code == "94287082")
        reject { custody.provision("a", seed(TotpCalculator.Algorithm.SHA1), TotpCalculator.Algorithm.SHA1, 8, 30, 1) }
        check((custody.generate("a", 59) as CodeResult.Code).value.code == "94287082")
    }
    // Store listing failure propagates out of reconcile and deletes nothing.
    run {
        val vault = FakeVault(); val custody0 = LocalSeedCustody(vault, FakeStore())
        custody0.provision("a", seed(TotpCalculator.Algorithm.SHA1), TotpCalculator.Algorithm.SHA1, 6, 30, 1)
        val broken = object : RecordStore by FakeStore() { override fun accountIds(): Set<String> = throw java.io.IOException("unreadable") }
        reject { LocalSeedCustody(vault, broken).reconcile() }
        check(vault.keys.size == 1)
    }
    // Bounded read works with short reads and never exceeds the limit (replaces API 33 readNBytes).
    run {
        val trickle = object : java.io.InputStream() { var i = 0; override fun read() = if (i < 1000) { i++; 65 } else -1
            override fun read(b: ByteArray, off: Int, len: Int): Int { if (i >= 1000) return -1; b[off] = 65; i++; return 1 } }
        check(readBounded(trickle, 401).size == 401)
        check(readBounded(java.io.ByteArrayInputStream(ByteArray(10)), 401).size == 10)
        check(readBounded(java.io.ByteArrayInputStream(ByteArray(0)), 401).isEmpty())
    }
    // Import failure and record-write failure both roll the key back: no orphan, no metadata.
    run {
        val vault = FakeVault().apply { failImport = true }; val store = FakeStore()
        reject { LocalSeedCustody(vault, store).provision("a", seed(TotpCalculator.Algorithm.SHA1), TotpCalculator.Algorithm.SHA1, 6, 30, 1) }
        check(vault.keys.isEmpty() && store.map.isEmpty())
        val vault2 = FakeVault(); val store2 = FakeStore().apply { failWrite = true }
        reject { LocalSeedCustody(vault2, store2).provision("a", seed(TotpCalculator.Algorithm.SHA1), TotpCalculator.Algorithm.SHA1, 6, 30, 1) }
        check(vault2.keys.isEmpty() && store2.map.isEmpty())
    }
    // Loss and reinstall: metadata without a key is KeyMissing and is never recreated or guessed; key without metadata is never used.
    run {
        val vault = FakeVault(); val store = FakeStore(); val custody = LocalSeedCustody(vault, store)
        custody.provision("a", seed(TotpCalculator.Algorithm.SHA1), TotpCalculator.Algorithm.SHA1, 6, 30, 1)
        vault.keys.clear() // uninstall/data clear/key loss
        check(custody.generate("a", 59) == CodeResult.KeyMissing)
        check(vault.keys.isEmpty() && store.map.containsKey("a")) { "nothing recreated" }
        check(custody.generate("never", 59) == CodeResult.NotProvisioned)
        check(custody.generate("bad id", 59) == CodeResult.NotProvisioned)
        // Orphan key (crash after import, before metadata): refused for use, removed by reconcile, foreign aliases untouched.
        vault.keys[SeedRecord.aliasFor("orphan")] = SecretKeySpec(seed(TotpCalculator.Algorithm.SHA1), "HmacSHA1")
        vault.keys["someone.else.key"] = SecretKeySpec(seed(TotpCalculator.Algorithm.SHA1), "HmacSHA1")
        check(custody.generate("orphan", 59) is CodeResult.Invalidated)
        check(custody.reconcile() == setOf(SeedRecord.aliasFor("orphan")))
        check("someone.else.key" in vault.keys && store.map.containsKey("a"))
    }
    // Delete ordering: metadata first. A crash between leaves an orphan (reconcile cleans), never metadata pointing at a missing key from delete.
    run {
        val vault = FakeVault(); val store = FakeStore(); val custody = LocalSeedCustody(vault, store)
        custody.provision("a", seed(TotpCalculator.Algorithm.SHA1), TotpCalculator.Algorithm.SHA1, 6, 30, 1)
        store.delete("a") // simulated crash after the first step of delete
        check(custody.generate("a", 59) is CodeResult.Invalidated)
        check(custody.reconcile().size == 1 && vault.keys.isEmpty())
        check(custody.generate("a", 59) == CodeResult.NotProvisioned)
    }
    // Platform refusals map to states, never to a fallback: invalidated, locked, unavailable.
    run {
        val vault = FakeVault(); val store = FakeStore(); val custody = LocalSeedCustody(vault, store)
        custody.provision("a", seed(TotpCalculator.Algorithm.SHA1), TotpCalculator.Algorithm.SHA1, 6, 30, 1)
        vault.keyError = VaultException.Kind.INVALIDATED; check(custody.generate("a", 59) is CodeResult.Invalidated)
        vault.keyError = VaultException.Kind.LOCKED; check(custody.generate("a", 59) == CodeResult.Locked)
        vault.keyError = VaultException.Kind.UNAVAILABLE; check(custody.generate("a", 59) is CodeResult.Unavailable)
        vault.keyError = null; check(custody.generate("a", 59) is CodeResult.Code)
        vault.wrongAlgorithm = true; check(custody.generate("a", 59) == CodeResult.Invalidated("algorithm_mismatch"))
        vault.wrongAlgorithm = false
        check(custody.generate("a", -1) is CodeResult.Unavailable)
    }
    class KeyPermanentlyInvalidatedException : Exception()
    class UserNotAuthenticatedException : Exception()
    check(classifyKeyFailure(java.security.InvalidKeyException("x", KeyPermanentlyInvalidatedException())) == CodeResult.Invalidated("key_invalidated"))
    check(classifyKeyFailure(java.security.InvalidKeyException(java.security.ProviderException(UserNotAuthenticatedException()))) == CodeResult.Locked)
    check(classifyKeyFailure(java.security.InvalidKeyException("other")) == CodeResult.Unavailable("key_rejected"))
    // Record codec: canonical only, exact version and field count, no duplicates or extras, alias derived, bounded.
    val record = SeedRecord("acct_1", SeedRecord.aliasFor("acct_1"), TotpCalculator.Algorithm.SHA256, 8, 60, "secure_hardware", 5)
    check(SeedRecord.decode(record.encode()) == record)
    for (broken in listOf(
        record.encode().replace("-v1", "-v2"), record.encode() + "x\n", record.encode().trimEnd('\n'), record.encode().replace("SHA256", "MD5"),
        record.encode().replace("\n8\n", "\n08\n"), record.encode().replace("\nsecure_hardware\n", "\nsecure_hardware\nsecure_hardware\n"), "", "a".repeat(500), record.encode().replace("acct_1", "acct 1"),
        record.encode().replace("\n60\n", "\n0\n"), record.encode().replace("\n5\n", "\n-5\n"),
    )) reject { SeedRecord.decode(broken) }
    // The record never carries seed material: encoding contains only the listed nonsecret fields.
    check(!record.encode().contains("1234567890"))
    println("PASS custody: RFC vectors via provisioned handles, create-only, rollback, loss/orphan/reconcile, delete order, refusal mapping, strict records; fake software vault, no Keystore/device evidence")
}
