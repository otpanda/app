package org.otpanda.totp

import android.content.Context
import android.os.Build
import java.io.File
import java.math.BigInteger
import java.security.KeyFactory
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec

// DEBUG/TEST ONLY. Phases for the seed-sync Keystore vault and the unregistered channel handler on the real Android Keystore with the real file stores,
// inside the debug fixture APK. SYNTHETIC owners and keys only; the production channel is not registered by this fixture. Each phase is a fresh
// instrumentation process. It prints what the platform reports and makes NO hardware-backing claim. NOT covered here: OS key invalidation (lock screen
// changes), uninstall, backup and restore, factory reset, a sealed seed batch (the JVM suite covers the batch flow with fakes). UNRUN on any device or emulator.
class FixtureV3(private val ctx: Context, private val out: (String) -> Unit) {
    private val real = AndroidSyncKeyVault()
    private val flaky = FlakySyncVault(real)
    private val custody = NativeSeedCustodyCore(AndroidSeedVault(), OwnerStateFileStore(ctx))
    private val core = SeedSyncKeyCore(flaky, SeedSyncStateFileStore(ctx), custody)
    private val now = 1_800_000_000_000L
    private val chl = "H".repeat(43)
    private val inst = "I".repeat(22)
    private val o = "fxs"
    private val h = SeedSyncChannelHandler(core, custody, { now })
    var oks = 0; private set
    private val pubFile get() = File(ctx.noBackupFilesDir, "fx-v3-pub.txt")
    private fun say(line: String) = out("FIXTURE api=${Build.VERSION.SDK_INT} $line")
    private fun need(ok: Boolean, what: String) { if (!ok) { say("FAIL $what"); throw FixtureFailure(what) }; oks++; say("ok $what") }
    private fun call(name: String, args: Map<String, Any?>?): ChannelReply = h.handle(name, args)
    private fun okv(r: ChannelReply): Any? = (r as? ChannelReply.Ok ?: throw FixtureFailure("expected ok, got $r")).value
    private fun errc(r: ChannelReply): String = (r as? ChannelReply.Err ?: throw FixtureFailure("expected err, got $r")).code
    private fun vaultErr(work: () -> Any?): VaultException.Kind? = try { work(); null } catch (e: VaultException) { e.kind }
    private fun seedAliases() = real.aliases().filter { it.startsWith("otpanda.seedsync.v1.") }

    private fun ecParams(): ECParameterSpec = java.security.AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }.getParameterSpec(ECParameterSpec::class.java)
    private fun pubKey(raw: ByteArray) = KeyFactory.getInstance("EC").generatePublic(
        ECPublicKeySpec(ECPoint(BigInteger(1, raw.copyOfRange(1, 33)), BigInteger(1, raw.copyOfRange(33, 65))), ecParams()))
    private fun verifyDer(raw: ByteArray, msg: ByteArray, der: ByteArray) = try {
        Signature.getInstance("SHA256withECDSA").run { initVerify(pubKey(raw)); update(msg); verify(der) } } catch (e: java.security.GeneralSecurityException) { false }
    private fun verifyWire(raw: ByteArray, msg: ByteArray, sig86: String) = verifyDer(raw, msg, SeedSyncWire.p1363ToDer(SeedSyncWire.unb64(sig86, 64)))
    private fun enroll(owner: String): Map<*, *> = okv(call("syncEnroll", mapOf("owner" to owner, "installId" to inst, "generation" to 1L))) as Map<*, *>
    private fun snapshotProof(owner: String, keyId: String): String = okv(call("syncSignSnapshotProof", mapOf("owner" to owner, "deviceId" to "device", "generation" to 1L,
        "epoch" to custody.readOwnerState(owner).epoch, "challenge" to chl, "expiresAt" to now + 60_000, "keyId" to keyId))) as String
    private fun snapshotMsg(owner: String, keyId: String) = SeedSyncWire.proofMessage(SyncPurpose.SNAPSHOT, mapOf("ownerId" to owner, "keyId" to keyId, "deviceId" to "device",
        "generation" to 1L, "epoch" to custody.readOwnerState(owner).epoch, "challenge" to chl, "expiresAt" to now + 60_000))
    private fun statusMsg(keyId: String) = SeedSyncWire.proofMessage(SyncPurpose.STATUS, mapOf("keyId" to keyId, "challenge" to chl, "expiresAt" to now + 60_000))
    private fun statusProof(owner: String, keyId: String): String = okv(call("syncStatusSign", mapOf("owner" to owner, "keyId" to keyId, "challenge" to chl, "expiresAt" to now + 60_000))) as String
    private fun statusKey(owner: String) = okv(call("syncStatusKeyId", mapOf("owner" to owner))) as String?

    fun run(phase: String) {
        when (phase) {
        "v3-vault" -> {
            val a = "otpanda.seedsync.v1.fxdirect"
            val pub = real.generate(a)
            need(pub.size == 65 && pub[0] == 4.toByte(), "generate returns a 65 byte uncompressed point")
            need(runCatching { SeedSyncWire.checkPoint(pub) }.isSuccess, "the point passes the strict curve check")
            need(vaultErr { real.generate(a) } == VaultException.Kind.UNAVAILABLE, "a duplicate alias is refused")
            val msg = "synthetic message".toByteArray()
            val der = real.sign(a, msg)
            need(verifyDer(pub, msg, der), "DER signature verifies with the JCA against the generated public key")
            need(SeedSyncWire.derToP1363(der).size == 64, "the DER signature converts strictly to 64 byte P1363")
            need(!verifyDer(pub, "other message".toByteArray(), der), "the signature does not verify for a different message")
            val bad = der.copyOf().also { it[it.size - 1] = (it[it.size - 1].toInt() xor 1).toByte() }
            need(!verifyDer(pub, msg, bad), "a tampered signature does not verify")
            val level = try {
                val k = java.security.KeyStore.getInstance("AndroidKeyStore").apply { load(null) }.getKey(a, null) as java.security.PrivateKey
                val info = java.security.KeyFactory.getInstance(k.algorithm, "AndroidKeyStore").getKeySpec(k, android.security.keystore.KeyInfo::class.java)
                @Suppress("DEPRECATION") if (info.isInsideSecureHardware) "secure_hardware" else "software"
            } catch (e: Exception) { say("RESULT v3-vault-level-error class=${e.javaClass.simpleName.replace("Exception", "Exc")}"); "unknown" }
            say("RESULT v3-vault-level=$level")
            real.delete(a)
            need(!real.containsAlias(a), "delete removes the alias")
            need(vaultErr { real.sign(a, msg) } == VaultException.Kind.INVALIDATED, "sign after delete is INVALIDATED")
            need(vaultErr { real.delete(a) } == null, "a second delete does not fail")
        }
        "v3-enroll" -> {
            val e = enroll(o)
            val keyId = e["keyId"] as String; val pub = e["publicKey"] as ByteArray
            need(pub.size == 65 && !e.containsKey("privateKey"), "enroll returns a public point and no private material")
            pubFile.writeText("$keyId ${SeedSyncWire.b64(pub)}")
            need(statusKey(o) == keyId, "the status key id is the enrolled key")
            need(verifyWire(pub, snapshotMsg(o, keyId), snapshotProof(o, keyId)), "snapshot proof verifies against the enrolled public key")
            need(verifyWire(pub, statusMsg(keyId), statusProof(o, keyId)), "status proof verifies against the enrolled public key")
            val st = okv(call("syncEnrollmentState", mapOf("owner" to o))) as Map<*, *>
            need(st["keyId"] == keyId && st["provable"] == true, "enrollment state reports a provable key")
            need(seedAliases().size == 1, "exactly one sync key alias exists")
            val e2 = enroll(o)
            need(e2["keyId"] != keyId && seedAliases().size == 1, "re-enroll replaces the key and leaves exactly one alias")
            pubFile.writeText("${e2["keyId"]} ${SeedSyncWire.b64(e2["publicKey"] as ByteArray)}")
        }
        "v3-restart" -> {
            val (keyId, pubB64) = pubFile.readText().split(" ")
            val pub = SeedSyncWire.unb64(pubB64, 65)
            need(core.enrolled(o), "enrollment survived the process restart")
            need(statusKey(o) == keyId, "the status key id is stable across restart")
            need(verifyWire(pub, statusMsg(keyId), statusProof(o, keyId)), "status proof after restart verifies with the stored public key")
            val st = okv(call("syncEnrollmentState", mapOf("owner" to o))) as Map<*, *>
            need(st["keyId"] == keyId && st["provable"] == false, "in a fresh process the key is not provable (no in-memory enrollment), so Dart must repair")
            need(seedAliases().size == 1, "exactly one sync key alias after restart")
            val d = okv(call("syncDiscoverOwners", null)) as Map<*, *>
            need((d["owners"] as List<*>).size == 1 && d["unreadable"] == 0L && d["complete"] == true, "discovery lists the owner with no session")
        }
        "v3-status" -> {
            val (keyId, _) = pubFile.readText().split(" ")
            need((okv(call("syncStatusApply", mapOf("owner" to o, "keyId" to "f".repeat(32), "state" to "key-revoked"))) as Map<*, *>)["outcome"] == "noop", "revoked status for another key id is a noop")
            need(errc(call("syncStatusApply", mapOf("owner" to o, "keyId" to keyId, "state" to "revoked"))) == "WIRE_STATUS", "an unknown state is refused")
            need(core.enrolled(o) && seedAliases().size == 1, "noop and refusal left the key in place")
            need((okv(call("syncStatusApply", mapOf("owner" to o, "keyId" to keyId, "state" to "key-revoked"))) as Map<*, *>)["outcome"] == "purged", "revoked status for the active key purges")
            need(statusKey(o) == null && !core.enrolled(o), "no status key id after the purge")
            need(seedAliases().isEmpty() && custody.readCatalog(o).entries.isEmpty(), "the sync key is deleted and no seeds remain")
        }
        "v3-missing" -> {
            val e = enroll(o); val keyId = e["keyId"] as String
            val alias = seedAliases().single()
            real.delete(alias) // behind the core's back: the closest available analogue of a lost key, NOT OS invalidation
            need(errc(call("syncSignSnapshotProof", mapOf("owner" to o, "deviceId" to "device", "generation" to 1L, "epoch" to custody.readOwnerState(o).epoch,
                "challenge" to chl, "expiresAt" to now + 60_000, "keyId" to keyId))) == "MISSING_KEY", "sign with a deleted key reports MISSING_KEY")
            need(core.enrolled(o), "a missing key alone does not purge or unenroll")
            okv(call("syncErase", mapOf("owner" to o, "epoch" to custody.readOwnerState(o).epoch, "trigger" to "sign_out")))
            need(!core.enrolled(o) && statusKey(o) == null, "erase clears the enrollment state")
        }
        "v3-pending" -> {
            val e = enroll(o); val keyId = e["keyId"] as String
            flaky.deleteDown = true
            val r = okv(call("syncErase", mapOf("owner" to o, "epoch" to custody.readOwnerState(o).epoch, "trigger" to "sign_out"))) as Map<*, *>
            need(r["keyDeleted"] == false, "erase reports the key delete as pending while the physical delete fails")
            need(statusKey(o) == null, "no status key id while the delete is pending")
            need(errc(call("syncSignSnapshotProof", mapOf("owner" to o, "deviceId" to "device", "generation" to 1L, "epoch" to custody.readOwnerState(o).epoch,
                "challenge" to chl, "expiresAt" to now + 60_000, "keyId" to keyId))) == "NOT_ENROLLED", "signing is refused with NOT_ENROLLED while the delete is pending")
            need(seedAliases().size == 1, "the key is still physically present while pending")
            need(core.pendingKeyDeletes(o) == 1, "one key delete is durably pending")
        }
        "v3-pending-retry" -> {
            need(core.pendingKeyDeletes(o) == 1 && seedAliases().size == 1, "pending delete survived the process restart")
            val rp = okv(call("syncRetryPending", null)) as Map<*, *>
            need(rp["keyDeletesPending"] == 0L, "retry in a new process clears the pending delete")
            need(seedAliases().isEmpty() && core.pendingKeyDeletes(o) == 0, "the pending key is physically gone")
        }
        "v3-install" -> {
            // The install id file on the real app filesystem, in a scratch directory of its own (never the production directory). Verifies the create-only hard link and the Os.open/fsync/close directory confirmation work for app data.
            val dir = File(ctx.noBackupFilesDir, "fx-install-scratch"); dir.deleteRecursively()
            val a = "A".repeat(43); val b = "B".repeat(43)
            val s = InstallIdFile(dir, AndroidDirSync())
            need(s.read() == null, "no install id before create")
            // Narrow synthetic diagnostics only. No production paths or data printed.
            fun probe(label: String, work: () -> Unit) {
                try { work(); say("RESULT v3-install-probe $label=ok") }
                catch (e: Exception) { say("RESULT v3-install-probe $label=" + e.javaClass.simpleName + ":" + e.message?.replace('\n', ' ')) }
            }
            probe("mkdir") { need(dir.mkdir() || dir.isDirectory, "scratch directory created") }
            probe("base-fsync") { AndroidDirSync().sync(ctx.noBackupFilesDir) }
            probe("dir-fsync") { AndroidDirSync().sync(dir) }
            val pt = File(dir, "probe-temp"); val pl = File(dir, "probe-link")
            probe("file-fsync") { java.io.FileOutputStream(pt).use { it.write(65); it.fd.sync() } }
            probe("java-link") { java.nio.file.Files.createLink(pl.toPath(), pt.toPath()) }
            pl.delete()
            probe("os-link") { android.system.Os.link(pt.path, pl.path) }
            pl.delete(); pt.delete()
            need(s.createIfAbsent(a) == (a to true), "create-only publish with the platform directory fsync works on this filesystem")
            need(InstallIdFile(dir, AndroidDirSync()).createIfAbsent(b) == (a to false), "a second creator gets the winner")
            need(InstallIdFile(dir, AndroidDirSync()).read() == a && dir.list()!!.toList() == listOf("install-id"), "one id file and no temp file remains")
            File(dir, "install-id").writeText("bad")
            need(runCatching { InstallIdFile(dir, AndroidDirSync()).read() }.exceptionOrNull() is InstallIdFailure, "a malformed file is reported unreadable")
            need(File(dir, "install-id").readText() == "bad", "a malformed file is never overwritten")
            dir.deleteRecursively()
            need(!dir.exists(), "scratch directory removed")
        }
        "v3-cleanup" -> {
            runCatching { okv(call("syncErase", mapOf("owner" to o, "epoch" to custody.readOwnerState(o).epoch, "trigger" to "sign_out"))) }
            need(core.retryPending().keyDeletesPending == 0, "no pending key deletes remain")
            for (a in real.aliases().filter { it.startsWith("otpanda.seedsync.v1.") }) real.delete(a)
            need(seedAliases().isEmpty(), "no sync key remains in the Keystore")
            pubFile.delete()
            need(!pubFile.exists(), "fixture scratch file removed")
        }
        else -> { say("FAIL unknown phase $phase"); throw FixtureFailure("unknown phase") }
        }
        say("END phase=$phase oks=$oks")
    }
}

/** Test seam over the REAL sync vault: only injects a failing delete. Never used outside the fixture. */
class FlakySyncVault(private val inner: SyncKeyVault) : SyncKeyVault by inner {
    var deleteDown = false
    override fun delete(alias: String) { if (deleteDown) throw VaultException(VaultException.Kind.UNAVAILABLE, "injected"); inner.delete(alias) }
}
