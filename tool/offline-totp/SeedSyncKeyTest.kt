package org.otpanda.totp

import java.security.KeyFactory
import java.security.Signature
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.security.AlgorithmParameters
import java.security.spec.ECParameterSpec
import java.math.BigInteger
import javax.crypto.SecretKey
import javax.crypto.spec.SecretKeySpec

// JVM tests for the seed-sync enrollment key and its deny-first erase state machine, against in-memory fakes with SYNTHETIC keys. NOT Keystore, hardware, lock,
// uninstall or backup evidence. A "process death" is modelled by an Error that no step catches, followed by a fresh core over the same durable fakes.
private class ProcessDeath : Error("simulated process death")

private class SVault : SyncKeyVault {
    val keys = LinkedHashMap<String, PrivateKey>(); val pubs = HashMap<String, ByteArray>()
    var deleteDown = false; var ignoreDelete = false; var deleteDeath = false; var listDown = false; var goneThenThrow = false
    val log = ArrayList<String>(); var onDelete: (String) -> Unit = {}
    override fun containsAlias(alias: String) = alias in keys
    override fun aliases(): Set<String> { if (listDown) throw VaultException(VaultException.Kind.UNAVAILABLE, "l"); return keys.keys.toSet() }
    override fun generate(alias: String): ByteArray {
        val g = KeyPairGenerator.getInstance("EC"); g.initialize(ECGenParameterSpec("secp256r1")); val kp = g.generateKeyPair()
        val w = (kp.public as java.security.interfaces.ECPublicKey).w
        fun fix(b: BigInteger) = b.toByteArray().let { if (it.size > 32) it.copyOfRange(it.size - 32, it.size) else ByteArray(32 - it.size) + it }
        val pub = byteArrayOf(4) + fix(w.affineX) + fix(w.affineY)
        keys[alias] = kp.private; pubs[alias] = pub; return pub
    }
    override fun sign(alias: String, message: ByteArray): ByteArray {
        val k = keys[alias] ?: throw VaultException(VaultException.Kind.INVALIDATED, "gone")
        return Signature.getInstance("SHA256withECDSA").run { initSign(k); update(message); sign() }
    }
    override fun delete(alias: String) {
        log.add("delete"); onDelete(alias)
        if (deleteDeath) throw ProcessDeath()
        if (deleteDown) throw VaultException(VaultException.Kind.UNAVAILABLE, "d")
        if (!ignoreDelete) keys.remove(alias)
        if (goneThenThrow) throw VaultException(VaultException.Kind.UNAVAILABLE, "notfound")
    }
}

private class SStore : SyncStateStore {
    val docs = HashMap<String, String>()
    var down = false; var writeDown = false; var writeDeathAt = -1; var writes = 0
    override fun read(key: String): String? { if (down) throw java.io.IOException("down"); return docs[key] }
    override fun write(key: String, text: String) {
        if (down || writeDown) throw java.io.IOException("down")
        if (writes++ == writeDeathAt) throw ProcessDeath()
        docs[key] = text
    }
    override fun keys(): Set<String> { if (down) throw java.io.IOException("down"); return docs.keys.toSet() }
}

private class CVault : KeyVault {
    val keys = HashMap<String, SecretKeySpec>(); var deleteDeath = false; var deleteDown = false; var deleteRuntime = false
    override fun containsAlias(alias: String) = alias in keys
    override fun aliases(): Set<String> = keys.keys.toSet()
    override fun importSeed(alias: String, seed: ByteArray, algorithm: TotpCalculator.Algorithm): ProtectionReport { keys[alias] = SecretKeySpec(seed.copyOf(), algorithm.jcaName); return ProtectionReport(true, "secure_hardware") }
    override fun key(alias: String): SecretKey? = keys[alias]
    override fun delete(alias: String) { if (deleteDeath) throw ProcessDeath(); if (deleteRuntime) throw IllegalStateException("boom"); if (deleteDown) throw VaultException(VaultException.Kind.UNAVAILABLE, "d"); keys.remove(alias) }
    override fun probe() = ProtectionReport(true, "x")
}
private class CStore : OwnerStateStore {
    val docs = HashMap<String, String>(); var down = false
    override fun read(key: String): String? { if (down) throw java.io.IOException("d"); return docs[key] }
    override fun write(key: String, text: String) { if (down) throw java.io.IOException("d"); docs[key] = text }
    override fun keys(): Set<String> { if (down) throw java.io.IOException("d"); return docs.keys.toSet() }
}

private class Rig(val sv: SVault = SVault(), val ss: SStore = SStore(), val cv: CVault = CVault(), val cs: CStore = CStore()) {
    var seq = 0
    val custody = NativeSeedCustodyCore(cv, cs)
    fun core(): SeedSyncKeyCore = SeedSyncKeyCore(sv, ss, custody) { (++seq + 1000L * ss.docs.size).toString(16).padStart(32, '0') }
    // a restart reuses the durable fakes but loses all memory; a different counter avoids alias reuse
    var c = core()
    fun restart(): SeedSyncKeyCore { seq += 500; c = core(); return c }
    fun seed(owner: String = "o", entry: String = "e", epoch: Long = 0) = custody.provision(owner, entry, 1, TotpCalculator.Algorithm.SHA1, 8, 30, "12345678901234567890".toByteArray(), epoch)
}

private fun err(w: () -> Any?): SyncKeyError? = try { w(); null } catch (e: SyncKeyFailure) { e.error }
private fun want(e: SyncKeyError, w: () -> Any?) { val g = err(w); check(g == e) { "expected $e got $g" } }
private fun died(w: () -> Any?): Boolean = try { w(); false } catch (_: ProcessDeath) { true }
private fun verifies(pub: ByteArray, msg: ByteArray, sig: ByteArray): Boolean {
    val ap = AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }.getParameterSpec(ECParameterSpec::class.java)
    val x = BigInteger(1, pub.copyOfRange(1, 33)); val y = BigInteger(1, pub.copyOfRange(33, 65))
    val k = KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), ap))
    return Signature.getInstance("SHA256withECDSA").run { initVerify(k); update(msg); verify(sig) }
}
private fun owners(r: Rig) = r.ss.docs.keys.toList()

fun main() {
    // 1. enroll, sign with the enrolled key only; the durable document holds ids and aliases, no key material.
    run {
        val r = Rig(); check(!r.c.enrolled("o"))
        want(SyncKeyError.NOT_ENROLLED) { r.c.sign("o", byteArrayOf(1)) }
        val en = r.c.enroll("o"); check(r.c.enrolled("o") && en.publicKey.size == 65 && en.publicKey[0] == 4.toByte())
        val m = "synthetic message".toByteArray(); check(verifies(en.publicKey, m, r.c.sign("o", m)))
        val doc = r.ss.docs.getValue(ownerKey("o")); check(doc.lines().first() == "otpanda-seedsync-state-v1" && !doc.contains("PRIVATE"))
        check(SyncState.decode(doc, "o").active != null)
        check(r.sv.keys.keys.all { it.startsWith("otpanda.seedsync.v1.") })
        check(r.cv.keys.isEmpty()) // never touches custody keys
        check(r.restart().enrolled("o")) // enrollment is durable
    }
    // 2. every purge trigger: key and seeds gone, deny cleared; DISABLE opts out, every other trigger leaves the default ON preference.
    for (t in EraseTrigger.values()) {
        val r = Rig(); r.c.enroll("o"); r.seed()
        val out = r.c.erase("o", 0, t)
        check(out.seedsPurged && out.keyDeleted && out.epoch == 1L) { "$t $out" }
        check(r.sv.keys.isEmpty() && r.cv.keys.isEmpty() && !r.c.enrolled("o") && r.c.pendingKeyDeletes("o") == 0) { "$t" }
        check(r.custody.readOwnerState("o").enabled == (t != EraseTrigger.DISABLE)) { "$t preference" }
        want(SyncKeyError.NOT_ENROLLED) { r.c.sign("o", byteArrayOf(1)) }
    }
    // 3. order: the deny commit is durable before the seeds are purged and before the vault delete.
    run {
        val r = Rig(); r.c.enroll("o"); r.seed()
        var docAtDelete = ""; var seedsAtDelete = -1
        r.sv.onDelete = { docAtDelete = r.ss.docs.getValue(ownerKey("o")); seedsAtDelete = r.cv.keys.size }
        r.c.erase("o", 0, EraseTrigger.SIGN_OUT)
        check(docAtDelete.contains("active none") && docAtDelete.contains("\ndeny ")) { "deny not committed before delete" }
        check(seedsAtDelete == 0) { "seeds not purged before key delete" }
    }
    // 4. delete fails or does not take: deny record kept, key never usable (this process, after restart), retried until a READ BACK shows it absent.
    for (mode in listOf("throws", "ignored")) {
        val r = Rig(); r.c.enroll("o"); r.seed()
        if (mode == "throws") r.sv.deleteDown = true else r.sv.ignoreDelete = true
        val out = r.c.erase("o", 0, EraseTrigger.SIGN_OUT)
        check(out.seedsPurged && !out.keyDeleted && r.sv.keys.size == 1 && r.c.pendingKeyDeletes("o") == 1) { mode }
        want(SyncKeyError.NOT_ENROLLED) { r.c.sign("o", byteArrayOf(1)) }
        val again = r.restart(); want(SyncKeyError.NOT_ENROLLED) { again.sign("o", byteArrayOf(1)) }
        check(again.retryPending().keyDeletesPending == 1 && r.sv.keys.size == 1)
        r.sv.deleteDown = false; r.sv.ignoreDelete = false
        check(again.retryPending().clean && r.sv.keys.isEmpty() && again.pendingKeyDeletes("o") == 0) { mode }
        check(r.ss.docs.getValue(ownerKey("o")).let { !it.contains("deny ") })
    }
    // 5. the commit itself cannot be written: the alias is still deleted best effort and the failure is reported; the stale document can never sign.
    run {
        val r = Rig(); r.c.enroll("o"); r.ss.writeDown = true
        want(SyncKeyError.ERASE_INCOMPLETE) { r.c.erase("o", 0, EraseTrigger.DISABLE) }
        check(r.sv.keys.isEmpty()); r.ss.writeDown = false
        want(SyncKeyError.ERASE_INCOMPLETE) { r.c.sign("o", byteArrayOf(1)) }
        want(SyncKeyError.MISSING_KEY) { r.restart().sign("o", byteArrayOf(1)) }
        check(r.c.erase("o", 0, EraseTrigger.SIGN_OUT).keyDeleted && !r.c.enrolled("o"))
    }
    // 6. process death at every step, then restart.
    run { // dies at the vault delete: deny already durable
        val r = Rig(); r.c.enroll("o"); r.seed(); r.sv.deleteDeath = true
        check(died { r.c.erase("o", 0, EraseTrigger.SIGN_OUT) }); r.sv.deleteDeath = false
        val a = r.restart(); want(SyncKeyError.NOT_ENROLLED) { a.sign("o", byteArrayOf(1)) }
        check(r.cv.keys.isEmpty() && a.pendingKeyDeletes("o") == 1 && r.sv.keys.size == 1)
        check(a.retryPending().clean && r.sv.keys.isEmpty())
    }
    run { // dies inside the custody seed delete: seeds pending in custody, key deny durable, nothing signs
        val r = Rig(); r.c.enroll("o"); r.seed(); r.cv.deleteDeath = true
        check(died { r.c.erase("o", 0, EraseTrigger.SIGN_OUT) }); r.cv.deleteDeath = false
        val a = r.restart(); want(SyncKeyError.ERASE_INCOMPLETE) { a.sign("o", byteArrayOf(1)) } // owed purge is durable
        check(a.retryPending().clean && r.sv.keys.isEmpty() && r.cv.keys.isEmpty())
    }
    run { // dies while clearing the deny record after a confirmed delete: the record survives, harmless, and the retry clears it
        val r = Rig(); r.c.enroll("o"); r.ss.writeDeathAt = r.ss.writes + 2 // write 0 commits deny+owed; write 1 clears owed; write 2 clears the deny record
        check(died { r.c.erase("o", 0, EraseTrigger.SIGN_OUT) }); r.ss.writeDeathAt = -1
        check(r.sv.keys.isEmpty() && r.restart().pendingKeyDeletes("o") == 1 && r.c.retryPending().clean && r.c.pendingKeyDeletes("o") == 0)
    }
    run { // dies while clearing the owed purge: the owed record survives, the key is still deleted, retry repeats the idempotent purge
        val r = Rig(); r.c.enroll("o"); r.seed(); r.ss.writeDeathAt = r.ss.writes + 1
        check(died { r.c.erase("o", 0, EraseTrigger.SIGN_OUT) }); r.ss.writeDeathAt = -1
        val a = r.restart(); check(a.purgeOwed("o") && r.cv.keys.isEmpty() && r.sv.keys.isEmpty())
        check(a.retryPending().clean && !a.purgeOwed("o"))
    }
    run { // dies between key creation and the durable write: orphan alias, never usable, swept
        val r = Rig(); r.ss.writeDeathAt = r.ss.writes
        check(died { r.c.enroll("o") }); r.ss.writeDeathAt = -1
        val a = r.restart(); check(!a.enrolled("o") && r.sv.keys.size == 1)
        want(SyncKeyError.NOT_ENROLLED) { a.sign("o", byteArrayOf(1)) }
        check(a.sweepOrphans().size == 1 && r.sv.keys.isEmpty())
        a.enroll("o"); check(a.enrolled("o"))
    }
    // 7. fresh alias on re-enrollment; the old key is denied and deleted; an unresolved old deletion does not block, and the old key never signs.
    run {
        val r = Rig(); val e1 = r.c.enroll("o"); val a1 = r.sv.keys.keys.single()
        val e2 = r.c.enroll("o"); check(e1.keyId != e2.keyId && a1 !in r.sv.keys && r.sv.keys.size == 1 && r.c.pendingKeyDeletes("o") == 0)
        r.sv.deleteDown = true; val a2 = r.sv.keys.keys.single()
        val e3 = r.c.enroll("o"); check(r.sv.keys.size == 2 && a2 in r.sv.keys && r.c.pendingKeyDeletes("o") == 1)
        val m = byteArrayOf(9); check(verifies(e3.publicKey, m, r.c.sign("o", m)) && !verifies(e2.publicKey, m, r.c.sign("o", m)))
        r.sv.deleteDown = false; check(r.c.retryPending().clean && r.sv.keys.size == 1)
    }
    // 8. custody failure after the key steps: the key is still denied and deleted, and the failure is not hidden. Too-high epoch behaves the same.
    run {
        val r = Rig(); r.c.enroll("o"); r.seed(); r.cs.down = true
        // the sync document store is separate, so only the custody step fails
        check(try { r.c.erase("o", 0, EraseTrigger.SIGN_OUT); false } catch (e: CustodyFailure) { e.error == CustodyError.METADATA_UNAVAILABLE })
        check(r.sv.keys.isEmpty() && !r.c.enrolled("o") && r.c.purgeOwed("o")); r.cs.down = false
        check(r.c.retryPending().clean && r.cv.keys.isEmpty() && !r.c.purgeOwed("o"))
        val q = Rig(); q.c.enroll("o"); q.seed()
        check(try { q.c.erase("o", 7, EraseTrigger.SIGN_OUT); false } catch (e: CustodyFailure) { e.error == CustodyError.EPOCH_MISMATCH })
        check(q.sv.keys.isEmpty() && !q.c.enrolled("o") && q.custody.readOwnerState("o").epoch == 0L && q.cv.keys.size == 1 && q.c.purgeOwed("o"))
        want(SyncKeyError.ERASE_INCOMPLETE) { q.c.enroll("o") }
        check(q.c.retryPending().clean && q.cv.keys.isEmpty() && q.custody.readOwnerState("o").epoch == 1L && !q.c.purgeOwed("o")) // real epoch, seeds removed, owed cleared only on success
        q.c.enroll("o") // allowed again
    }
    // 9. unreadable or corrupt state fails closed everywhere; seeds are still purged; nothing is deleted blindly.
    run {
        val r = Rig(); r.c.enroll("o"); r.seed(); val doc = r.ss.docs.getValue(ownerKey("o"))
        for (bad in listOf("corrupt", doc.replace("deny", "deni") + "x", doc.replace("owner ", "owner A"))) {
            r.ss.docs[ownerKey("o")] = bad
            want(SyncKeyError.METADATA_UNAVAILABLE) { r.c.sign("o", byteArrayOf(1)) }
            want(SyncKeyError.METADATA_UNAVAILABLE) { r.c.enroll("o") }
            check(r.c.retryPending().let { it.unreadableOwners == 1 && !it.clean }) // counted, never deleted blindly
            want(SyncKeyError.METADATA_UNAVAILABLE) { r.c.sweepOrphans() }
            check(r.sv.keys.size == 1)
        }
        want(SyncKeyError.METADATA_UNAVAILABLE) { r.c.erase("o", 0, EraseTrigger.SIGN_OUT) }
        check(r.cv.keys.isEmpty() && r.sv.keys.size == 1) // seeds purged, key unusable but not deleted blindly
        r.ss.docs[ownerKey("o")] = doc; r.ss.down = true
        want(SyncKeyError.ERASE_INCOMPLETE) { r.c.sign("o", byteArrayOf(1)) } // the lost erase intent still blocks the key; the store is down
        want(SyncKeyError.METADATA_UNAVAILABLE) { r.c.retryPending() }
        r.ss.down = false // the document is readable again: the retry now commits the erase that was requested earlier and deletes the key
        check(r.c.retryPending().clean && r.sv.keys.isEmpty() && !r.c.enrolled("o"))
    }
    // 10. owners are independent; the sweep only touches seed-sync aliases that no document references.
    run {
        val r = Rig(); r.c.enroll("a"); r.c.enroll("b")
        r.sv.keys["otpanda.totp.v2.custody-alias"] = r.sv.keys.values.first(); r.sv.keys["otpanda.seedsync.v1." + "f".repeat(32)] = r.sv.keys.values.first()
        check(r.c.sweepOrphans() == setOf("otpanda.seedsync.v1." + "f".repeat(32)) && "otpanda.totp.v2.custody-alias" in r.sv.keys)
        r.c.erase("a", 0, EraseTrigger.OWNER_SWITCH); check(!r.c.enrolled("a") && r.c.enrolled("b")); r.c.sign("b", byteArrayOf(1))
        check(r.sv.keys.keys.count { it.startsWith("otpanda.seedsync.v1.") } == 1)
        r.sv.listDown = true; want(SyncKeyError.UNAVAILABLE) { r.c.sweepOrphans() }
    }
    // 11. remote codes: only the four definitive codes purge; expiry suspends; everything else changes nothing.
    run {
        for (c in listOf("seed-sync-key-revoked", "device-revoked", "session-revoked", "security-generation-changed")) check(classifyRemoteCode(c) == RemoteCodeAction.PURGE && eraseTriggerFor(c) != null)
        for (c in listOf("session-expired", "idle-expired")) check(classifyRemoteCode(c) == RemoteCodeAction.SUSPEND && eraseTriggerFor(c) == null)
        for (c in listOf(null, "", "401", "403", "500", "invalid_grant", "captive-portal", "Seed-Sync-Key-Revoked", " device-revoked", "device-revoked\n", "timeout", "clock-skew")) check(classifyRemoteCode(c) == RemoteCodeAction.IGNORE && eraseTriggerFor(c) == null) { "code $c" }
    }
    // 12. strict codec
    run {
        val r = Rig(); r.c.enroll("o"); val doc = r.ss.docs.getValue(ownerKey("o")); SyncState.decode(doc, "o")
        val a = doc.lines()[2].substringAfterLast(' ')
        for (bad in listOf(doc.replace("active ", "active  "), doc.replace("\nend\n", "\n"), doc.replace("v1.", "v2."), doc.replace("\nend\n", "\ndeny ${"0".repeat(32)} $a\nend\n"), doc.replace("\nend\n", "\n\nend\n")))
            check(runCatching { SyncState.decode(bad, "o") }.isFailure) { "accepted: $bad" }
        check(runCatching { SyncState.decode(doc, "other") }.isFailure)
        check(runCatching { SyncState.decode("x".repeat(70000), "o") }.isFailure)
    }
    // 13. invalid owner ids
    run { val r = Rig(); for (bad in listOf("", "a\u0000b", "x".repeat(129))) { want(SyncKeyError.INVALID_INPUT) { r.c.enroll(bad) }; want(SyncKeyError.INVALID_INPUT) { r.c.erase(bad, 0, EraseTrigger.SIGN_OUT) } } }
    // 14. commit fails AND delete fails: sign and enroll refuse at once (in-memory intent), seeds are still purged, ERASE_INCOMPLETE is typed; retryPending commits it.
    run {
        val r = Rig(); r.c.enroll("o"); r.seed(); r.ss.writeDown = true; r.sv.deleteDown = true
        want(SyncKeyError.ERASE_INCOMPLETE) { r.c.erase("o", 0, EraseTrigger.SIGN_OUT) }
        check(r.cv.keys.isEmpty() && r.sv.keys.size == 1)
        want(SyncKeyError.ERASE_INCOMPLETE) { r.c.sign("o", byteArrayOf(1)) }
        want(SyncKeyError.ERASE_INCOMPLETE) { r.c.enroll("o") }
        check(!r.c.enrolled("o"))
        check(!r.c.retryPending().clean) // still down: still blocked
        want(SyncKeyError.ERASE_INCOMPLETE) { r.c.sign("o", byteArrayOf(1)) }
        r.ss.writeDown = false; r.sv.deleteDown = false
        check(r.c.retryPending().clean && r.sv.keys.isEmpty() && !r.c.purgeOwed("o"))
        want(SyncKeyError.NOT_ENROLLED) { r.c.sign("o", byteArrayOf(1)) }
        // documented gap: a process death in that window loses the memory intent; only the caller's persisted intent re-running erase recovers it
        val g = Rig(); g.c.enroll("o"); g.ss.writeDown = true; g.sv.deleteDown = true
        want(SyncKeyError.ERASE_INCOMPLETE) { g.c.erase("o", 0, EraseTrigger.SIGN_OUT) }
        g.ss.writeDown = false; g.sv.deleteDown = false
        check(g.restart().enrolled("o")) // stale durable state says active
        check(g.c.erase("o", 0, EraseTrigger.SIGN_OUT).keyDeleted && !g.c.enrolled("o"))
    }
    // 15. a RuntimeException (not a CustodyFailure) from custody still deletes the key; the owed purge stays durable and a retry finishes it.
    run {
        val r = Rig(); r.c.enroll("o"); r.seed(); r.cv.deleteRuntime = true
        val thrown = try { r.c.erase("o", 0, EraseTrigger.SIGN_OUT).let { if (it.seedsPurged) "purged" else null } } catch (e: Exception) { e }
        check(thrown != "purged") { "must not report a purge that did not finish" } // custody may map it to a pending purge or let it escape; both are not-done
        check(r.sv.keys.isEmpty() && r.c.purgeOwed("o") && !r.c.enrolled("o"))
        want(SyncKeyError.ERASE_INCOMPLETE) { r.c.sign("o", byteArrayOf(1)) }
        r.cv.deleteRuntime = false
        check(r.c.retryPending().clean && r.cv.keys.isEmpty() && !r.c.purgeOwed("o"))
    }
    // 16. an Error from the vault inside custody (modelled death) still reaches the key delete before it propagates, and the owed record survives.
    run {
        val r = Rig(); r.c.enroll("o"); r.seed(); r.cv.deleteDeath = true
        check(died { r.c.erase("o", 0, EraseTrigger.DISABLE) })
        check(r.sv.keys.isEmpty() && r.c.purgeOwed("o")); r.cv.deleteDeath = false
        check(r.restart().retryPending().clean && r.cv.keys.isEmpty() && !r.custody.readOwnerState("o").enabled) // DISABLE keeps its opt-out when retried
    }
    // Retry alone finishes physical seed deletion for purge and persistent disable; repeated failures remain bounded/fail closed.
    for (trigger in listOf(EraseTrigger.SIGN_OUT, EraseTrigger.DISABLE)) {
        val r = Rig(); r.c.enroll("o"); r.seed(); r.cv.deleteDown = true
        check(!r.c.erase("o", 0, trigger).seedsPurged && r.c.purgeOwed("o"))
        val firstEpoch = r.custody.readOwnerState("o").epoch
        repeat(5) {
            check(!r.c.retryPending().clean && r.c.purgeOwed("o"))
            check(r.custody.readOwnerState("o").epoch == firstEpoch)
            want(SyncKeyError.ERASE_INCOMPLETE) { r.c.sign("o", byteArrayOf(1)) }
            want(SyncKeyError.ERASE_INCOMPLETE) { r.c.enroll("o") }
        }
        r.cv.deleteDown = false
        check(r.c.retryPending().clean && r.cv.keys.isEmpty() && !r.c.purgeOwed("o"))
        check(r.custody.readOwnerState("o").enabled == (trigger != EraseTrigger.DISABLE))
        if (trigger == EraseTrigger.DISABLE) r.custody.enableOwner("o", r.custody.readOwnerState("o").epoch)
        r.c.enroll("o")
    }
    // A stale caller must erase all owner keys at the real native epoch; repeat erase recaptures an advanced native epoch.
    for (trigger in listOf(EraseTrigger.SIGN_OUT, EraseTrigger.DISABLE)) {
        val r = Rig(); r.c.enroll("o"); r.custody.enableOwner("o", 3); r.seed(epoch = 3)
        check(r.c.erase("o", 0, trigger).seedsPurged && r.cv.keys.isEmpty() && !r.c.purgeOwed("o"))
        check(r.custody.readOwnerState("o").epoch == 4L)
        val q = Rig(); q.c.enroll("o"); q.seed(); q.cv.deleteDown = true
        check(!q.c.erase("o", 0, trigger).seedsPurged)
        q.custody.enableOwner("o", 3); q.seed(entry = "new", epoch = 3)
        check(!q.c.erase("o", 0, trigger).seedsPurged && q.c.purgeOwed("o"))
        val captured = q.custody.readOwnerState("o").epoch
        check(captured == 4L)
        repeat(5) { check(!q.c.retryPending().clean && q.custody.readOwnerState("o").epoch == captured) }
        q.cv.deleteDown = false
        check(q.restart().retryPending().clean && q.cv.keys.isEmpty() && !q.c.purgeOwed("o"))
    }
    run {
        val r = Rig(); r.c.enroll("o"); r.custody.enableOwner("o", 3); r.seed(epoch = 3)
        check(try { r.c.erase("o", 9, EraseTrigger.SIGN_OUT); false } catch (e: CustodyFailure) { e.error == CustodyError.EPOCH_MISMATCH })
        check(r.c.purgeOwed("o") && r.cv.keys.isNotEmpty())
        want(SyncKeyError.ERASE_INCOMPLETE) { r.c.enroll("o") }
        check(r.restart().retryPending().clean && r.cv.keys.isEmpty())
        val q = Rig(); q.c.enroll("o"); q.custody.enableOwner("o", 9); q.seed(epoch = 9); q.cv.deleteDown = true
        check(!q.c.erase("o", 9, EraseTrigger.SIGN_OUT).seedsPurged)
        q.cs.docs.clear(); q.cv.keys.clear() // explicit native metadata/vault reset; sync metadata still owes epoch 9
        q.seed(epoch = 0); q.cv.deleteDown = false
        check(q.restart().retryPending().clean && q.cv.keys.isEmpty() && !q.c.purgeOwed("o"))
    }
    // 17. retry isolation: one unreadable owner never stops the others; its document is left untouched.
    run {
        val r = Rig(); r.c.enroll("a"); r.c.enroll("b"); r.c.enroll("c"); r.seed("b")
        r.sv.deleteDown = true; r.c.erase("b", 0, EraseTrigger.OWNER_SWITCH); r.sv.deleteDown = false
        val badDoc = "corrupt"; r.ss.docs[ownerKey("a")] = badDoc
        val res = r.c.retryPending()
        check(res.unreadableOwners == 1 && res.keyDeletesPending == 0 && r.ss.docs[ownerKey("a")] == badDoc)
        check(r.sv.keys.size == 2 && r.c.enrolled("c")) // a's alias kept (not grounded), b's removed
    }
    // 18. denies are bounded at 16: enroll refuses before the document could exceed it, and erase still decodes.
    run {
        val r = Rig(); r.sv.deleteDown = true
        var n = 0
        while (err { r.c.enroll("o") } == null) { n++; check(n < 40) }
        check(n == 16 && r.c.pendingKeyDeletes("o") == 15)
        r.c.erase("o", 0, EraseTrigger.SIGN_OUT)
        check(r.c.pendingKeyDeletes("o") == 16 && SyncState.decode(r.ss.docs.getValue(ownerKey("o")), "o").deny.size <= 16)
        r.sv.deleteDown = false; check(r.c.retryPending().clean && r.sv.keys.isEmpty()); r.c.enroll("o")
    }
    // 19. absent alias and fresh read-back: a delete that throws after the alias is gone counts as deleted; erasing with the alias already absent is fine.
    run {
        val r = Rig(); r.c.enroll("o"); r.sv.goneThenThrow = true
        check(r.c.erase("o", 0, EraseTrigger.SIGN_OUT).keyDeleted && r.sv.keys.isEmpty()); r.sv.goneThenThrow = false
        val q = Rig(); q.c.enroll("o"); q.sv.keys.clear()
        check(q.c.erase("o", 0, EraseTrigger.SIGN_OUT).keyDeleted && q.c.pendingKeyDeletes("o") == 0)
    }
    // 20. explicit recovery from a corrupt document: never automatic, owes a purge, then the orphan sweep removes the now-unreferenced alias.
    run {
        val r = Rig(); r.c.enroll("o"); r.seed(); val good = r.ss.docs.getValue(ownerKey("o"))
        want(SyncKeyError.INVALID_INPUT) { r.c.resetUnreadableState("o") } // valid document: refused
        r.ss.docs[ownerKey("o")] = "corrupt"
        want(SyncKeyError.METADATA_UNAVAILABLE) { r.c.erase("o", 0, EraseTrigger.SIGN_OUT) }
        check(r.cv.keys.isEmpty() && r.sv.keys.size == 1) // seeds purged; the key is not deleted without grounding
        want(SyncKeyError.METADATA_UNAVAILABLE) { r.c.enroll("o") }
        want(SyncKeyError.METADATA_UNAVAILABLE) { r.c.sweepOrphans() }
        r.c.resetUnreadableState("o")
        check(r.c.purgeOwed("o") && r.sv.keys.size == 1)
        want(SyncKeyError.ERASE_INCOMPLETE) { r.c.enroll("o") }
        check(r.c.retryPending().clean && r.c.sweepOrphans().size == 1 && r.sv.keys.isEmpty())
        r.c.enroll("o"); check(r.c.enrolled("o")); check(good.isNotEmpty())
    }
    println("PASS seed-sync enrollment key and deny-first erase state machine (JVM fakes, synthetic keys, simulated process death)")
}
