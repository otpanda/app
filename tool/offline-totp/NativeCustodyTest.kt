package org.otpanda.totp

import javax.crypto.SecretKey
import javax.crypto.spec.SecretKeySpec

// JVM logic tests for NativeSeedCustodyCore against in-memory fakes. NOT Keystore, hardware, lock, uninstall or backup evidence.
private class V2Vault : KeyVault {
    val keys = HashMap<String, SecretKeySpec>()
    var hardware = true
    var importError: VaultException.Kind? = null
    var keyError: VaultException.Kind? = null
    var deleteDown = false
    var listDown = false
    var wrongAlgorithm = false
    override fun containsAlias(alias: String) = alias in keys
    override fun aliases(): Set<String> { if (listDown) throw VaultException(VaultException.Kind.UNAVAILABLE, "list"); return keys.keys.toSet() }
    override fun importSeed(alias: String, seed: ByteArray, algorithm: TotpCalculator.Algorithm): ProtectionReport {
        importError?.let { throw VaultException(it, "import") }
        keys[alias] = SecretKeySpec(seed.copyOf(), if (wrongAlgorithm) "HmacSHA1" else algorithm.jcaName)
        return ProtectionReport(hardware, if (hardware) "secure_hardware" else "software")
    }
    override fun key(alias: String): SecretKey? { keyError?.let { throw VaultException(it, "key") }; return keys[alias] }
    override fun delete(alias: String) { if (deleteDown) throw VaultException(VaultException.Kind.UNAVAILABLE, "del"); keys.remove(alias) }
    override fun probe(): ProtectionReport { importError?.let { throw VaultException(it, "probe") }; return ProtectionReport(hardware, "x") }
}

private class V2Store : OwnerStateStore {
    val docs = HashMap<String, String>()
    var down = false
    var writeDown = false
    override fun read(key: String): String? { if (down) throw java.io.IOException("down"); return docs[key] }
    override fun write(key: String, text: String) { if (down || writeDown) throw java.io.IOException("down"); docs[key] = text }
    override fun keys(): Set<String> { if (down) throw java.io.IOException("down"); return docs.keys.toSet() }
}

private val SHA1 = TotpCalculator.Algorithm.SHA1
private val S1 = "12345678901234567890".toByteArray()
private fun s1() = S1.copyOf()
private fun err(work: () -> Any?): CustodyError? = try { work(); null } catch (e: CustodyFailure) { e.error }
private fun want(e: CustodyError, work: () -> Any?) { val got = err(work); check(got == e) { "expected $e got $got" } }
private fun hexOf(b: ByteArray) = b.joinToString("") { "%02x".format(it) }

private class Env(val vault: V2Vault = V2Vault(), val store: V2Store = V2Store()) {
    val c = NativeSeedCustodyCore(vault, store)
    fun prov(o: String = "o", e: String = "e", v: Long = 1, ep: Long = 0, d: Int = 8, p: Int = 30, alg: TotpCalculator.Algorithm = SHA1) = c.provision(o, e, v, alg, d, p, s1(), ep)
    fun gen(o: String = "o", e: String = "e", v: Long = 1, t: Long = 59) = c.generate(o, e, v, t)
}

fun main() {
    // Cross-language pin: the Dart custodyAad output for these inputs (computed with the Dart contract at the fixed tag).
    val expected = "0000001d6f7470616e64612d6e61746976652d736565642d7265636f72642d7631000000076f776e6572203100000008656e7472792fc3a900000001370000000673686132353600000001370000000236300000000133"
    check(hexOf(custodyAad("owner 1", "entry/\u00e9", 7, TotpCalculator.Algorithm.SHA256, 7, 60, 3)) == expected) { "AAD differs from Dart" }

    // Provision then generate; RFC 6238 SHA1 vector; seed zeroed.
    run {
        val t = Env(); val seed = s1(); t.c.provision("o", "e", 1, SHA1, 8, 30, seed, 0)
        check(seed.all { it == 0.toByte() }); check(t.gen() == "94287082")
        check(t.vault.keys.size == 1 && t.store.docs.size == 1)
        check(t.store.docs.values.none { it.contains("12345678901234567890") })
    }
    // Software-backed keys are accepted (user decision 2026-11-26) and capability reports honestly.
    run {
        val t = Env(V2Vault().apply { hardware = false }); t.prov(); check(t.gen() == "94287082")
        check(t.c.capability().protection == Protection.OS_ENCRYPTED)
        t.vault.hardware = true; check(t.c.capability().protection == Protection.HARDWARE_HMAC)
        t.vault.importError = VaultException.Kind.UNAVAILABLE; check(t.c.capability().protection == Protection.UNAVAILABLE)
    }
    // Input validation.
    run {
        val t = Env()
        want(CustodyError.INVALID_INPUT) { t.c.provision("o", "e", 1, SHA1, 8, 30, ByteArray(5) { 1 }, 0) }
        want(CustodyError.INVALID_INPUT) { t.c.provision("o", "e", 1, SHA1, 8, 30, ByteArray(129) { 1 }, 0) }
        want(CustodyError.INVALID_INPUT) { t.prov(o = "") }
        want(CustodyError.INVALID_INPUT) { t.prov(e = "a\u0000b") }
        want(CustodyError.INVALID_INPUT) { t.prov(e = "x".repeat(129)) }
        want(CustodyError.INVALID_INPUT) { t.prov(v = 0) }
        want(CustodyError.INVALID_INPUT) { t.prov(v = CUSTODY_MAX_SAFE_INT + 1) }
        want(CustodyError.INVALID_INPUT) { t.prov(ep = -1) }
        want(CustodyError.INVALID_INPUT) { t.prov(d = 9) }
        want(CustodyError.INVALID_INPUT) { t.prov(p = 0) }
        check(t.vault.keys.isEmpty() && t.store.docs.isEmpty())
    }
    // Rotation: higher version replaces; lower and equal conflict; the old key is deleted; the old version is denied.
    run {
        val t = Env(); t.prov(v = 1); t.prov(v = 2, d = 6)
        check(t.vault.keys.size == 1)
        want(CustodyError.VERSION_CONFLICT) { t.prov(v = 2) }
        want(CustodyError.VERSION_CONFLICT) { t.prov(v = 1) }
        want(CustodyError.VERSION_CONFLICT) { t.gen(v = 1) }
        check(t.gen(v = 2).length == 6)
    }
    // Epoch rules: only local lifecycle moves the epoch.
    run {
        val t = Env()
        want(CustodyError.EPOCH_MISMATCH) { t.prov(ep = 1) }
        t.prov(ep = 0)
        want(CustodyError.NOT_FOUND) { t.gen(e = "other") }
        // clearOwner(0): epoch -> 1, disabled, record purged and denied
        check(t.c.clearOwner("o", 0).purged)
        want(CustodyError.NOT_FOUND) { t.gen() } // purged: nothing pending
    }
    run {
        val t = Env(); t.prov(); t.vault.deleteDown = true
        val r = t.c.clearOwner("o", 0); check(!r.purged && r.denied)
        want(CustodyError.DENIED) { t.gen() } // logical deny with the store down
        want(CustodyError.DISABLED) { t.prov(ep = 1) }
        want(CustodyError.DISABLED) { t.c.reconcile("o", Snapshot(1, 1, true, emptyMap())) }
        check(t.c.purgePending() == listOf("o/e")); t.vault.deleteDown = false
        check(t.c.purgePending().isEmpty() && t.vault.keys.isEmpty())
        want(CustodyError.NOT_FOUND) { t.gen() }
        want(CustodyError.DISABLED) { t.prov(ep = 1) }
        want(CustodyError.STALE_EPOCH) { t.c.enableOwner("o", 0) }
        t.c.enableOwner("o", 1); t.prov(ep = 1); check(t.gen() == "94287082")
        // an older clear never lowers the epoch nor disables, and spares newer records
        check(t.c.clearOwner("o", 0).denied); check(t.gen() == "94287082"); t.prov(e = "f", ep = 1)
        want(CustodyError.STALE_EPOCH) { t.prov(e = "g", ep = 0) }
        // floors restart with the epoch
        t.c.delete("o", "f", 5); want(CustodyError.VERSION_CONFLICT) { t.prov(e = "f", v = 5, ep = 1) }
        t.c.clearOwner("o", 1); t.c.enableOwner("o", 2); t.prov(e = "f", v = 1, ep = 2)
    }
    // Delete keeps a floor even with no record; a newer version still provisions; a newer record survives a stale delete.
    run {
        val t = Env()
        t.c.delete("o", "e", 3)
        want(CustodyError.VERSION_CONFLICT) { t.prov(v = 3) }
        t.prov(v = 4); t.c.delete("o", "e", 2); check(t.gen(v = 4) == "94287082")
        t.c.delete("o", "e", 4); want(CustodyError.NOT_FOUND) { t.gen(v = 4) }
        want(CustodyError.INVALID_INPUT) { t.c.delete("o", "e", 0) }
    }
    // Delete with the vault down: logical deny first, purge pending.
    run {
        val t = Env(); t.prov(); t.vault.deleteDown = true
        t.c.delete("o", "e", 1); want(CustodyError.DENIED) { t.gen() }
        check(t.vault.keys.size == 1 && t.c.purgePending() == listOf("o/e"))
        t.vault.deleteDown = false; check(t.c.purgePending().isEmpty() && t.vault.keys.isEmpty())
    }
    // Reconcile.
    run {
        val t = Env(); t.prov(e = "a"); t.prov(e = "b"); t.prov(e = "c")
        var r = t.c.reconcile("o", Snapshot(0, 1, true, mapOf("a" to 1L, "d" to 2L), mapOf("c" to 1L)))
        check(r.removed == listOf("b", "c") && r.needsProvision == listOf("d")) { "$r" }
        want(CustodyError.NOT_FOUND) { t.gen(e = "b") }
        check(t.gen(e = "a") == "94287082")
        want(CustodyError.STALE_SNAPSHOT) { t.c.reconcile("o", Snapshot(0, 1, true, mapOf("a" to 1L))) }
    }
    run {
        val t = Env(); t.prov(e = "a")
        want(CustodyError.INVALID_SNAPSHOT) { t.c.reconcile("o", Snapshot(0, 0, true, mapOf())) }
        want(CustodyError.INVALID_SNAPSHOT) { t.c.reconcile("o", Snapshot(0, 1, true, mapOf("a" to 1L), mapOf("a" to 1L))) }
        want(CustodyError.INVALID_SNAPSHOT) { t.c.reconcile("o", Snapshot(0, 1, true, mapOf("" to 1L))) }
        want(CustodyError.INVALID_SNAPSHOT) { t.c.reconcile("o", Snapshot(0, 1, true, (0..5000).associate { "k$it" to 1L })) }
        t.c.clearOwner("o", 0); t.c.enableOwner("o", 1)
        want(CustodyError.STALE_EPOCH) { t.c.reconcile("o", Snapshot(0, 9, true, mapOf())) }
        want(CustodyError.EPOCH_MISMATCH) { t.c.reconcile("o", Snapshot(2, 1, true, mapOf())) }
    }
    // Superseded: a listed higher version denies the local one; minAccept blocks a lower provision.
    run {
        val t = Env(); t.prov(e = "a", v = 1)
        val r = t.c.reconcile("o", Snapshot(0, 1, false, mapOf("a" to 3L)))
        check(r.superseded == listOf("a") && r.needsProvision == listOf("a"))
        want(CustodyError.NOT_FOUND) { t.gen(e = "a") }
        want(CustodyError.VERSION_CONFLICT) { t.prov(e = "a", v = 2) }
        t.prov(e = "a", v = 3); check(t.gen(e = "a", v = 3) == "94287082")
        // minAccept is never lowered by a later snapshot
        t.c.reconcile("o", Snapshot(0, 2, false, mapOf("a" to 1L)))
        t.c.delete("o", "a", 3); want(CustodyError.VERSION_CONFLICT) { t.prov(e = "a", v = 3) }
        // tombstone with no local record sets a floor
        t.c.reconcile("o", Snapshot(0, 3, false, mapOf(), mapOf("z" to 4L)))
        want(CustodyError.VERSION_CONFLICT) { t.prov(e = "z", v = 4) }
    }
    // Owners are isolated; the same entry id under another owner is independent.
    run {
        val t = Env(); t.prov(o = "o1"); t.prov(o = "o2"); t.c.clearOwner("o1", 0)
        check(t.gen(o = "o2") == "94287082"); check(t.vault.keys.size == 1)
    }
    // Tamper: edited record fields, swapped aliases, wrong key algorithm.
    run {
        val t = Env(); t.prov(e = "a"); t.prov(e = "b", d = 6)
        val k = t.store.docs.keys.single(); val doc = t.store.docs.getValue(k)
        t.store.docs[k] = doc.replace(" SHA1 8 30 ", " SHA1 6 30 ")
        want(CustodyError.TAMPER) { t.gen(e = "a") }
        t.store.docs[k] = doc.replace(" SHA1 8 30 ", " SHA1 8 31 ")
        want(CustodyError.TAMPER) { t.gen(e = "a") }
        t.store.docs[k] = doc; check(t.gen(e = "a") == "94287082")
        val t2 = Env(V2Vault().apply { wrongAlgorithm = true }); t2.prov(alg = TotpCalculator.Algorithm.SHA256)
        want(CustodyError.TAMPER) { t2.gen() }
        // a malformed or non-canonical document fails closed
        t.store.docs[k] = doc + "junk\n"; want(CustodyError.METADATA_UNAVAILABLE) { t.gen(e = "a") }
        t.store.docs[k] = doc.replace("epoch 0", "epoch 00"); want(CustodyError.METADATA_UNAVAILABLE) { t.gen(e = "a") }
        // a document moved to another owner's key is refused
        t.store.docs[ownerKey("evil")] = doc; want(CustodyError.METADATA_UNAVAILABLE) { t.gen(o = "evil", e = "a") }
    }
    // Missing key, locked and unavailable vault.
    run {
        val t = Env(); t.prov()
        t.vault.keys.clear(); want(CustodyError.MISSING_KEY) { t.gen() }
        t.vault.keyError = VaultException.Kind.LOCKED; want(CustodyError.LOCKED) { t.gen() }
        t.vault.keyError = VaultException.Kind.UNAVAILABLE; want(CustodyError.UNAVAILABLE) { t.gen() }
        t.vault.keyError = VaultException.Kind.INVALIDATED; want(CustodyError.MISSING_KEY) { t.gen() }
        val l = Env(); l.vault.importError = VaultException.Kind.LOCKED
        want(CustodyError.LOCKED) { l.prov() }; check(l.store.docs.isEmpty() && l.vault.keys.isEmpty())
        l.vault.importError = VaultException.Kind.UNSUPPORTED_SEED; want(CustodyError.INVALID_INPUT) { l.prov() }
    }
    // Metadata down: every operation fails and changes nothing; a failed state write rolls the key back.
    run {
        val t = Env(); t.prov(); val before = HashMap(t.store.docs); val keysBefore = t.vault.keys.keys.toSet()
        t.store.down = true
        want(CustodyError.METADATA_UNAVAILABLE) { t.prov(e = "n") }
        want(CustodyError.METADATA_UNAVAILABLE) { t.gen() }
        want(CustodyError.METADATA_UNAVAILABLE) { t.c.delete("o", "e", 1) }
        want(CustodyError.METADATA_UNAVAILABLE) { t.c.clearOwner("o", 0) }
        want(CustodyError.METADATA_UNAVAILABLE) { t.c.enableOwner("o", 1) }
        want(CustodyError.METADATA_UNAVAILABLE) { t.c.reconcile("o", Snapshot(0, 1, true, mapOf())) }
        want(CustodyError.METADATA_UNAVAILABLE) { t.c.purgePending() }
        want(CustodyError.METADATA_UNAVAILABLE) { t.c.sweepOrphans() }
        t.store.down = false; check(t.store.docs == before && t.vault.keys.keys == keysBefore)
        t.store.writeDown = true; want(CustodyError.METADATA_UNAVAILABLE) { t.prov(e = "n") }
        check(t.vault.keys.keys == keysBefore) { "key rolled back after failed state write" }
        t.store.writeDown = false; check(t.store.docs == before)
    }
    // Orphan sweep: removes unreferenced v2 keys, spares referenced, pending and foreign aliases; aborts on unreadable state or listing errors.
    run {
        val t = Env(); t.prov(); t.vault.keys["otpanda.totp.v2." + "0".repeat(64)] = SecretKeySpec(S1, "HmacSHA1"); t.vault.keys["other.app.key"] = SecretKeySpec(S1, "HmacSHA1")
        val gone = t.c.sweepOrphans(); check(gone == setOf("otpanda.totp.v2." + "0".repeat(64)))
        check(t.vault.keys.size == 2 && t.gen() == "94287082")
        t.vault.deleteDown = true; t.c.delete("o", "e", 1); t.vault.deleteDown = false
        check(t.c.sweepOrphans().isEmpty() && t.vault.keys.size == 2) { "pending alias is not an orphan" }
        val k = t.store.docs.keys.single(); val doc = t.store.docs.getValue(k); t.store.docs[k] = "garbage"
        t.vault.keys["otpanda.totp.v2." + "1".repeat(64)] = SecretKeySpec(S1, "HmacSHA1")
        want(CustodyError.METADATA_UNAVAILABLE) { t.c.sweepOrphans() }; check(t.vault.keys.containsKey("otpanda.totp.v2." + "1".repeat(64)))
        t.store.docs[k] = doc; t.vault.listDown = true; want(CustodyError.UNAVAILABLE) { t.c.sweepOrphans() }
    }
    // Interrupted provision leaves an orphan key that the same provision overwrites and the sweep removes.
    run {
        val t = Env(); val a = custodyAlias("o", "e", 1, SHA1, 8, 30, 0)
        t.vault.keys[a] = SecretKeySpec(ByteArray(20) { 9 }, "HmacSHA1"); t.prov(); check(t.gen() == "94287082")
    }
    channelTests()
    println("PASS NativeCustodyTest (JVM fakes only)")
}

// Channel adapter: argument strictness and error-code mapping (no Flutter involved).
internal fun channelTests() {
    val t = Env(); val h = NativeCustodyChannelHandler(t.c)
    fun ok(r: ChannelReply) = (r as? ChannelReply.Ok) ?: error("expected Ok got $r")
    fun code(r: ChannelReply) = (r as? ChannelReply.Err)?.code
    val base = mapOf("owner" to "o", "entry" to "e", "seedVersion" to 1, "epoch" to 0L, "algorithm" to "sha1", "digits" to 8, "periodSeconds" to 30)
    val seed = s1()
    ok(h.handle("provision", base + ("seed" to seed))); check(seed.all { it == 0.toByte() })
    check(ok(h.handle("generate", mapOf("owner" to "o", "entry" to "e", "seedVersion" to 1L, "unixSeconds" to 59L))).value == "94287082")
    check(code(h.handle("generate", mapOf("owner" to "o", "entry" to "e", "seedVersion" to 2L, "unixSeconds" to 59L))) == "VERSION_CONFLICT")
    // wrong types, missing fields, unknown algorithm, null arguments: INVALID_INPUT, seed zeroed, nothing changes
    val s2 = s1(); check(code(h.handle("provision", base + ("seed" to s2) + ("digits" to "8"))) == "INVALID_INPUT"); check(s2.all { it == 0.toByte() })
    check(code(h.handle("provision", base + ("seed" to s1()) + ("seedVersion" to 2.0))) == "INVALID_INPUT")
    check(code(h.handle("provision", base + ("seed" to s1()) + ("algorithm" to "md5"))) == "INVALID_INPUT")
    check(code(h.handle("provision", base)) == "INVALID_INPUT")
    check(code(h.handle("generate", null)) == "INVALID_INPUT")
    check(code(h.handle("provision", base + ("seed" to s1()) + ("digits" to 4294967304L))) == "INVALID_INPUT")
    check(code(h.handle("provision", base + ("seed" to s1()) + ("periodSeconds" to 4294967326L))) == "INVALID_INPUT")
    check(code(h.handle("provision", base + ("seed" to s1()) + ("unexpected" to true))) == "INVALID_INPUT")
    check(code(h.handle("capability", mapOf("unexpected" to true))) == "INVALID_INPUT")
    check(h.handle("nope", null) == ChannelReply.NotImplemented)
    check(code(h.handle("reconcile", mapOf("owner" to "o", "snapshot" to mapOf("epoch" to 0, "revision" to 1, "complete" to "yes", "versions" to mapOf<String, Long>(), "tombstones" to mapOf<String, Long>())))) == "INVALID_INPUT")
    val rc = ok(h.handle("reconcile", mapOf("owner" to "o", "snapshot" to mapOf("epoch" to 0, "revision" to 1, "complete" to true, "versions" to mapOf("e" to 1L), "tombstones" to mapOf<String, Long>()))))
    check((rc.value as Map<*, *>)["removed"] == emptyList<String>())
    t.store.down = true; check(code(h.handle("purgePending", null)) == "METADATA_UNAVAILABLE"); t.store.down = false
    check((ok(h.handle("clearOwner", mapOf("owner" to "o", "epoch" to 0))).value as Map<*, *>)["denied"] == true)
    check(ok(h.handle("capability", null)).value != null)
    println("PASS channel adapter argument strictness and error mapping (JVM fakes only)")
}
