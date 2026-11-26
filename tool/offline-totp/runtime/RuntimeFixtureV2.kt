package org.otpanda.totp

import android.content.Context
import android.os.Build
import javax.crypto.spec.SecretKeySpec

// DEBUG/TEST ONLY. Phases for native custody v2 on the real Android Keystore with the real file store, inside the debug fixture APK. RFC 6238 seeds only.
// Each phase is a fresh instrumentation process, so restarts are real process restarts. It does not use the software-key seam and makes no
// hardware-qualification claim: it prints what the platform reported. UNRUN until the manual emulator workflow executes it.
class FixtureV2(private val ctx: Context, private val out: (String) -> Unit) {
    private val real = AndroidSeedVault()
    private val file = OwnerStateFileStore(ctx)
    private val vault = FlakyVault(real)
    private val store = FlakyStore(file)
    private val c = NativeSeedCustodyCore(vault, store)
    var oks = 0; private set
    private val o = "fxo"
    private val s1 = "12345678901234567890".toByteArray(Charsets.US_ASCII)
    private val s256 = "12345678901234567890123456789012".toByteArray(Charsets.US_ASCII)
    private val s512 = "1234567890123456789012345678901234567890123456789012345678901234".toByteArray(Charsets.US_ASCII)
    private fun say(line: String) = out("FIXTURE api=${Build.VERSION.SDK_INT} $line")
    private fun need(ok: Boolean, what: String) { if (!ok) { say("FAIL $what"); throw FixtureFailure(what) }; oks++; say("ok $what") }
    private fun errOf(work: () -> Any?): CustodyError? = try { work(); null } catch (e: CustodyFailure) { e.error }
    private fun alias(entry: String, v: Long, a: TotpCalculator.Algorithm, d: Int, p: Int) = custodyAlias(o, entry, v, a, d, p, 0)
    private fun prov(entry: String, v: Long, a: TotpCalculator.Algorithm, d: Int, p: Int, seed: ByteArray, owner: String = o) =
        c.provision(owner, entry, v, a, d, p, seed.copyOf(), 0)

    fun run(phase: String) {
        when (phase) {
        "v2-capability" -> {
            val cap = c.capability()
            say("RESULT v2-capability protection=${cap.protection} reason=${cap.reason}")
            need(cap.protection != Protection.UNAVAILABLE, "probe reports a usable Keystore (hardware or OS-encrypted); either is accepted")
            need(real.aliases().none { it.startsWith("otpanda.totp.probe.") }, "probe left no key behind")
        }
        "v2-provision" -> {
            // Acceptance is by observation: whatever level the platform reports is accepted; a refusal would be a failed need, not a silent skip.
            prov("fxsha1", 1, TotpCalculator.Algorithm.SHA1, 8, 30, s1)
            prov("fxsha256", 1, TotpCalculator.Algorithm.SHA256, 8, 30, s256)
            prov("fxsha512", 1, TotpCalculator.Algorithm.SHA512, 8, 30, s512)
            need(c.generate(o, "fxsha1", 1, 59) == "94287082", "SHA1 RFC code via provisioned key")
            need(c.generate(o, "fxsha256", 1, 59) == "46119246", "SHA256 RFC code via provisioned key")
            need(c.generate(o, "fxsha512", 1, 59) == "90693936", "SHA512 RFC code via provisioned key")
            for (e in listOf("fxsha1", "fxsha256", "fxsha512")) say("RESULT v2-level $e=${c.levelOf(o, e)}")
            need(real.aliases().count { it.startsWith("otpanda.totp.v2.") } == 3, "exactly three v2 keys exist")
        }
        "v2-restart" -> {
            need(c.generate(o, "fxsha1", 1, 59) == "94287082", "SHA1 key survived process restart")
            need(c.generate(o, "fxsha512", 1, 59) == "90693936", "SHA512 key survived process restart")
            need(errOf { c.provision(o, "fxsha1", 9, TotpCalculator.Algorithm.SHA1, 8, 30, s1.copyOf(), 1) } == CustodyError.EPOCH_MISMATCH,
                "epoch persisted: a higher epoch is refused after restart")
        }
        "v2-rotate" -> {
            val old = alias("fxsha1", 1, TotpCalculator.Algorithm.SHA1, 8, 30)
            prov("fxsha1", 2, TotpCalculator.Algorithm.SHA1, 6, 30, s1)
            need(c.generate(o, "fxsha1", 2, 59) == "287082", "rotated version generates with its new digits")
            need(errOf { c.generate(o, "fxsha1", 1, 59) } == CustodyError.VERSION_CONFLICT, "old version refused")
            need(errOf { prov("fxsha1", 1, TotpCalculator.Algorithm.SHA1, 8, 30, s1) } == CustodyError.VERSION_CONFLICT, "downgrade refused")
            need(!real.containsAlias(old), "old key deleted from the Keystore")
            c.delete(o, "fxsha1", 2)
            need(errOf { c.generate(o, "fxsha1", 2, 59) } == CustodyError.NOT_FOUND, "deleted entry is gone")
            need(errOf { prov("fxsha1", 2, TotpCalculator.Algorithm.SHA1, 6, 30, s1) } == CustodyError.VERSION_CONFLICT, "delete floor blocks resurrection at the deleted version")
            prov("fxsha1", 3, TotpCalculator.Algorithm.SHA1, 8, 30, s1)
            need(c.generate(o, "fxsha1", 3, 59) == "94287082", "a newer version provisions after delete")
        }
        "v2-pending" -> {
            // A physical delete that fails (injected wrapper over the REAL Keystore) leaves the record denied and the key pending.
            vault.deleteDown = true
            c.delete(o, "fxsha256", 1); c.delete(o, "fxsha512", 1)
            need(errOf { c.generate(o, "fxsha256", 1, 59) } == CustodyError.DENIED, "logical deny while the physical delete fails")
            need(real.containsAlias(alias("fxsha256", 1, TotpCalculator.Algorithm.SHA256, 8, 30)), "key still physically present while pending")
            need(c.purgePending() == listOf("$o/fxsha256", "$o/fxsha512"), "purge reports both pending while delete keeps failing")
            // deleteDown stays true until this process ends; the pending state is durable and the next phase (new process) retries it.
        }
        "v2-pending-retry" -> {
            need(errOf { c.generate(o, "fxsha256", 1, 59) } == CustodyError.DENIED, "deny survived process restart while the key is still pending")
            need(real.containsAlias(alias("fxsha256", 1, TotpCalculator.Algorithm.SHA256, 8, 30)), "key still present before retry")
            need(c.purgePending().isEmpty(), "retry in a new process clears every pending delete")
            need(!real.containsAlias(alias("fxsha256", 1, TotpCalculator.Algorithm.SHA256, 8, 30)) && !real.containsAlias(alias("fxsha512", 1, TotpCalculator.Algorithm.SHA512, 8, 30)), "pending keys physically gone")
            need(errOf { c.generate(o, "fxsha256", 1, 59) } == CustodyError.NOT_FOUND, "after purge the entry is simply absent")
            need(errOf { prov("fxsha256", 1, TotpCalculator.Algorithm.SHA256, 8, 30, s256) } == CustodyError.VERSION_CONFLICT, "delete floor still blocks the deleted version")
        }
        "v2-metadata" -> {
            prov("fxmeta", 1, TotpCalculator.Algorithm.SHA1, 8, 30, s1, owner = "fxo2")
            val text = file.read(ownerKey("fxo2"))!!
            store.down = true
            need(errOf { c.generate("fxo2", "fxmeta", 1, 59) } == CustodyError.METADATA_UNAVAILABLE, "generate fails closed when metadata is down")
            need(errOf { c.delete("fxo2", "fxmeta", 1) } == CustodyError.METADATA_UNAVAILABLE, "delete changes nothing when metadata is down")
            need(errOf { c.clearOwner("fxo2", 0) } == CustodyError.METADATA_UNAVAILABLE, "clearOwner changes nothing when metadata is down")
            store.down = false
            need(file.read(ownerKey("fxo2")) == text, "state unchanged by the failed operations")
            need(c.generate("fxo2", "fxmeta", 1, 59) == "94287082", "works again when metadata returns")
            store.writeDown = true
            val keysBefore = real.aliases()
            need(errOf { prov("fxw", 1, TotpCalculator.Algorithm.SHA1, 8, 30, s1, owner = "fxo2") } == CustodyError.METADATA_UNAVAILABLE, "provision fails when the state write fails")
            need(real.aliases() == keysBefore, "failed state write rolled the new key back")
            store.writeDown = false
            file.write(ownerKey("fxo2"), "not a state document")
            need(errOf { c.generate("fxo2", "fxmeta", 1, 59) } == CustodyError.METADATA_UNAVAILABLE, "corrupt state document fails closed")
            need(errOf { c.sweepOrphans() } == CustodyError.METADATA_UNAVAILABLE, "orphan sweep aborts on a corrupt state document")
            need(real.containsAlias(custodyAlias("fxo2", "fxmeta", 1, TotpCalculator.Algorithm.SHA1, 8, 30, 0)), "abort deleted nothing")
            file.write(ownerKey("fxo2"), text)
            need(c.generate("fxo2", "fxmeta", 1, 59) == "94287082", "restored state works")
        }
        "v2-keylen" -> {
            for (n in listOf(10, 20, 32, 64, 65, 100, 128)) {
                val seed = ByteArray(n) { (it * 7 + 3).toByte() }
                val outcome = try {
                    c.provision("fxk", "k$n", 1, TotpCalculator.Algorithm.SHA512, 8, 30, seed.copyOf(), 0)
                    val expected = TotpCalculator.generate(SecretKeySpec(seed, "HmacSHA512"), 1_700_000_000, TotpCalculator.Algorithm.SHA512, 8, 30).code
                    if (c.generate("fxk", "k$n", 1, 1_700_000_000) == expected) "ok" else "WRONG_CODE"
                } catch (e: CustodyFailure) { e.error.name }
                say("RESULT keylen $n=$outcome")
                if (n <= 64) need(outcome == "ok", "seed of $n bytes works and matches a software HMAC")
                else need(outcome != "WRONG_CODE", "seed of $n bytes is either refused or correct (never a wrong code)")
            }
        }
        "v2-cleanup" -> {
            for (owner in listOf(o, "fxo2", "fxk")) c.clearOwner(owner, 0)
            need(c.purgePending().isEmpty(), "no pending deletes remain")
            need(c.sweepOrphans().isEmpty(), "no orphan keys remain")
            need(real.aliases().none { it.startsWith("otpanda.totp.v2.") }, "no v2 key remains in the Keystore")
        }
        else -> { say("FAIL unknown phase $phase"); throw FixtureFailure("unknown phase") }
        }
        say("END phase=$phase oks=$oks")
    }
}

/** Test seam over the REAL vault: only injects a failing delete. Never used outside the fixture. */
class FlakyVault(private val inner: KeyVault) : KeyVault by inner {
    var deleteDown = false
    override fun delete(alias: String) { if (deleteDown) throw VaultException(VaultException.Kind.UNAVAILABLE, "injected"); inner.delete(alias) }
}

/** Test seam over the REAL file store: only injects failures. */
class FlakyStore(private val inner: OwnerStateStore) : OwnerStateStore {
    var down = false
    var writeDown = false
    override fun read(key: String): String? { if (down) throw java.io.IOException("injected"); return inner.read(key) }
    override fun write(key: String, text: String) { if (down || writeDown) throw java.io.IOException("injected"); inner.write(key, text) }
    override fun keys(): Set<String> { if (down) throw java.io.IOException("injected"); return inner.keys() }
}
