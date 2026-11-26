package org.otpanda.totp

import android.content.Context
import android.os.Build
import java.io.File

// DEBUG/TEST ONLY. Runs inside the debug-only fixture APK (see FixtureRunner.kt) with the APK's real app UID and application context, using only
// the published RFC 6238 test seeds. It is the only non-test file allowed to name the software-key seam (release-guard.sh). Each phase runs in a
// fresh instrumentation process, so restart phases are real process restarts. It makes no hardware-qualification claim: it prints what the platform reported.
class FixtureFailure(message: String) : Exception(message)

class Fixture(ctx: Context, private val out: (String) -> Unit) {
    private val vault = AndroidSeedVault()
    private val store = NoBackupSeedRecordStore(ctx)
    private val secure = LocalSeedCustody(vault, store)
    private val seamed = LocalSeedCustody(vault, store, allowSoftwareKeysForTests = true)
    var oks = 0; private set
    private val seeds = mapOf(
        "fxsha1" to Triple(TotpCalculator.Algorithm.SHA1, "12345678901234567890", "94287082"),
        "fxsha256" to Triple(TotpCalculator.Algorithm.SHA256, "12345678901234567890123456789012", "46119246"),
        "fxsha512" to Triple(TotpCalculator.Algorithm.SHA512, "1234567890123456789012345678901234567890123456789012345678901234", "90693936"),
    )
    private fun say(line: String) = out("FIXTURE api=${Build.VERSION.SDK_INT} $line")
    private fun need(ok: Boolean, what: String) { if (!ok) { say("FAIL $what"); throw FixtureFailure(what) }; oks++; say("ok $what") }
    private fun code(id: String) = (secure.generate(id, 59) as? CodeResult.Code)?.value?.code
    private fun cleanAll() {
        for (id in seeds.keys + "fxbig") runCatching { seamed.delete(id) }
        runCatching { seamed.reconcile() }
    }
    private fun provision(c: LocalSeedCustody, id: String) {
        val (alg, text, _) = seeds.getValue(id)
        c.provision(id, text.toByteArray(Charsets.US_ASCII), alg, 8, 30, 1_700_000_000)
    }

    /** Runs one phase. Throws on any failed check. The END marker is printed only after every check passed. */
    fun run(phase: String) {
        when (phase) {
        "env" -> say("env fingerprint=${Build.FINGERPRINT} model=${Build.MODEL}")
        "secure-default" -> {
            cleanAll()
            // Observed, not assumed: the default must either accept a key the platform reports as secure hardware, or refuse and leave nothing.
            val outcome = try { provision(secure, "fxsha1"); "accepted" } catch (e: CustodyException) { e.reason }
            if (outcome == "accepted") {
                need(store.read("fxsha1")?.protection == "secure_hardware", "default accepted only a key reported as secure_hardware")
                need(code("fxsha1") == "94287082", "default-accepted key generates the RFC code")
            } else {
                need(outcome == "protection_too_weak", "default refusal reason is protection_too_weak (got $outcome)")
                need(!vault.containsAlias(SeedRecord.aliasFor("fxsha1")), "refused key rolled back from Keystore")
                need(store.accountIds().isEmpty(), "refused provision left no record")
            }
            say("RESULT secure-default outcome=$outcome")
            cleanAll()
        }
        "seam-provision" -> {
            cleanAll()
            for (id in seeds.keys) provision(seamed, id)
            for ((id, v) in seeds) need(code(id) == v.third, "seam-provisioned $id generates RFC code")
            for (id in seeds.keys) say("RESULT level $id=${store.read(id)?.protection}")
            need(runCatching { provision(seamed, "fxsha1") }.exceptionOrNull() is CustodyException, "second provision refused (create-only)")
        }
        "seam-restart" -> { // new process: nothing in memory survives
            need(secure.accounts().keys == seeds.keys, "records survived process restart")
            for ((id, v) in seeds) need(code(id) == v.third, "$id still generates after restart")
        }
        "seam-loss" -> {
            vault.delete(SeedRecord.aliasFor("fxsha1")) // simulated key loss; uninstall/reinstall is NOT simulated here
            need(secure.generate("fxsha1", 59) == CodeResult.KeyMissing, "record without key reports KeyMissing")
            need(!vault.containsAlias(SeedRecord.aliasFor("fxsha1")), "missing key was not recreated")
            need(code("fxsha256") == "46119246", "other accounts unaffected")
            need(secure.reconcile().isEmpty(), "reconcile does not touch records or live keys")
        }
        "seam-orphan" -> {
            store.delete("fxsha256") // record gone, key remains: crash-after-import shape
            need(secure.generate("fxsha256", 59) is CodeResult.Invalidated, "key without record is refused")
            need(secure.reconcile().contains(SeedRecord.aliasFor("fxsha256")), "reconcile removes the orphan key")
            provision(seamed, "fxsha256")
            need(code("fxsha256") == "46119246", "re-provision after orphan cleanup works")
        }
        "size" -> { // observation only: records what this platform does with a 65-byte HMAC seed
            val outcome = try { seamed.provision("fxbig", ByteArray(65) { 7 }, TotpCalculator.Algorithm.SHA512, 8, 30, 1_700_000_000); "accepted" } catch (e: CustodyException) { e.reason }
            say("RESULT size65 outcome=$outcome")
        }
        "cleanup" -> { cleanAll(); need(secure.accounts().isEmpty() && store.accountIds().isEmpty(), "cleaned: no records remain") }
        else -> { say("FAIL unknown phase $phase"); throw FixtureFailure("unknown phase") }
    }
        // Printed only after every check of the phase passed; a crash or failed check never reaches it.
        say("END phase=$phase oks=$oks")
    }
}
