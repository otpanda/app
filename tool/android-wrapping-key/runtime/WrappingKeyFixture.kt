package org.otpanda.wrappingkey.fixture

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.UserManager
import org.otpanda.wrappingkey.*
import java.io.File
import java.security.KeyStore

// DEBUG/TEST ONLY. Runs in the fixture APK (own package, own UID, own Keystore namespace) with the REAL androidWrappingKeyCore: real AndroidKeyStore, real
// directory fsync, real noBackupFilesDir. Synthetic namespaces (fx-*) only; it never touches production aliases. Each phase is a fresh instrumentation process,
// so "reopen" is a real process restart. It claims nothing about hardware backing or a locked device; see the README for what an emulator cannot show.
class FixtureFailure(message: String) : Exception(message)

class WrappingKeyFixture(private val ctx: Context, private val out: (String) -> Unit) {
    var oks = 0; private set
    private val core = androidWrappingKeyCore(ctx)
    private val keyDir = File(ctx.noBackupFilesDir, "otpanda-wrapping-key-v1")
    private fun say(line: String) = out("FIXTURE api=${Build.VERSION.SDK_INT} $line")
    private fun need(ok: Boolean, what: String) { if (!ok) { say("FAIL $what"); throw FixtureFailure(what) }; oks++; say("ok $what") }
    private fun blob(ns: String) = File(keyDir, "$ns.key")
    private fun alias(ns: String) = "otpanda.wrapkey.v1.$ns"
    private fun ks() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private fun hasAlias(ns: String) = ks().containsAlias(alias(ns))
    private fun dropAlias(ns: String) = ks().deleteEntry(alias(ns))
    private fun key(seed: Int) = ByteArray(32) { (seed + it).toByte() }
    private fun failure(body: () -> Unit): WrappingKeyFailure? = try { body(); null } catch (e: WrappingKeyFailure) { e }
    private fun expectKind(what: String, kind: WrappingKeyFailure.Kind, body: () -> Unit) {
        val f = failure(body)
        need(f != null && f.kind == kind, "$what -> ${kind.name}${if (f != null && f.kind != kind) " (got ${f.kind.name})" else if (f == null) " (no failure)" else ""}")
    }
    private fun waitFor(f: File, ms: Long): String? { val end = System.currentTimeMillis() + ms; while (System.currentTimeMillis() < end) { if (f.exists()) return f.readText(); Thread.sleep(50) }; return null }
    private fun wipe(vararg ns: String) { for (n in ns) { runCatching { core.delete(n) }; runCatching { dropAlias(n) }; runCatching { blob(n).delete() } } }

    fun run(phase: String) {
        when (phase) {
        "env" -> {
            val um = ctx.getSystemService(UserManager::class.java)
            say("env fingerprint=${Build.FINGERPRINT} model=${Build.MODEL}")
            need(um?.isUserUnlocked == true, "user storage unlocked (the locked path is NOT exercised on an emulator)")
            need(ctx.noBackupFilesDir.isDirectory, "noBackupFilesDir exists")
            wipe("fx-main", "fx-dup", "fx-lost", "fx-corrupt", "fx-orphan", "fx-threads", RACE_NS, CRASH_NS, "fx-del")
            ctx.noBackupFilesDir.listFiles()?.filter { it.name.startsWith("fx-wk-") }?.forEach { it.delete() }
            need(!blob("fx-main").exists() && !hasAlias("fx-main"), "synthetic namespaces start clean")
        }
        "create" -> {
            need(core.read("fx-main") == null, "read before create is absent (null), not an error")
            val (k, created) = core.createIfAbsent("fx-main", key(1))
            need(created && k.contentEquals(key(1)), "real Keystore create returns the candidate, created=true")
            need(blob("fx-main").length() == 61L, "blob is exactly 61 bytes (version+iv+key+tag)")
            need(hasAlias("fx-main"), "Keystore alias exists")
            need(blob("fx-main").canonicalPath.startsWith(ctx.noBackupFilesDir.canonicalPath), "blob lives under noBackupFilesDir")
            need(keyDir.listFiles().orEmpty().none { it.name.contains(".tmp-") }, "no temp files left after create")
        }
        "reopen" -> {
            val k = core.read("fx-main")
            need(k != null && k.contentEquals(key(1)), "new process reads the same key from the real Keystore")
            val blobBefore = blob("fx-main").readBytes()
            val (k2, created) = core.createIfAbsent("fx-main", key(99))
            need(!created && k2.contentEquals(key(1)), "create after reopen returns the existing key, not the new candidate")
            need(blobBefore.contentEquals(blob("fx-main").readBytes()), "blob bytes unchanged by the duplicate create")
        }
        "duplicate" -> {
            val a = core.createIfAbsent("fx-dup", key(10)); val b = core.createIfAbsent("fx-dup", key(20))
            need(a.second && !b.second && b.first.contentEquals(key(10)), "second create returns the first winner")
        }
        "alias-lost" -> {
            core.createIfAbsent("fx-lost", key(30))
            dropAlias("fx-lost")
            val before = blob("fx-lost").readBytes()
            need(!hasAlias("fx-lost"), "Keystore alias removed out from under the blob")
            expectKind("read with blob but no alias", WrappingKeyFailure.Kind.MISSING_ALIAS) { core.read("fx-lost") }
            expectKind("create with blob but no alias", WrappingKeyFailure.Kind.MISSING_ALIAS) { core.createIfAbsent("fx-lost", key(31)) }
            need(blob("fx-lost").exists() && before.contentEquals(blob("fx-lost").readBytes()), "blob preserved byte for byte")
            need(!hasAlias("fx-lost"), "no alias regenerated by read or create")
        }
        "alias-lost-restart" -> {
            expectKind("read in a new process, blob but no alias", WrappingKeyFailure.Kind.MISSING_ALIAS) { core.read("fx-lost") }
            need(blob("fx-lost").exists() && !hasAlias("fx-lost"), "state unchanged after restart")
            core.delete("fx-lost")
            need(!blob("fx-lost").exists() && core.read("fx-lost") == null, "explicit purge clears it; read is absent afterwards")
        }
        "corrupt" -> {
            core.createIfAbsent("fx-corrupt", key(40))
            val f = blob("fx-corrupt"); val b = f.readBytes(); b[b.size - 1] = (b[b.size - 1].toInt() xor 1).toByte(); f.writeBytes(b)
            val tampered = f.readBytes()
            expectKind("flipped tag byte", WrappingKeyFailure.Kind.CORRUPT) { core.read("fx-corrupt") }
            expectKind("create over corrupt blob", WrappingKeyFailure.Kind.CORRUPT) { core.createIfAbsent("fx-corrupt", key(41)) }
            need(tampered.contentEquals(f.readBytes()) && hasAlias("fx-corrupt"), "corrupt blob and alias both untouched")
            f.writeBytes(tampered.copyOf(30))
            expectKind("truncated blob", WrappingKeyFailure.Kind.CORRUPT) { core.read("fx-corrupt") }
            need(f.length() == 30L, "truncated blob not repaired or deleted")
            f.delete(); f.mkdir()
            expectKind("directory in place of blob", WrappingKeyFailure.Kind.CORRUPT) { core.read("fx-corrupt") }
            need(f.isDirectory, "directory left in place")
            f.delete()
            core.delete("fx-corrupt")
        }
        "orphan" -> {
            core.createIfAbsent("fx-orphan", key(50))
            blob("fx-orphan").delete()
            need(hasAlias("fx-orphan") && core.read("fx-orphan") == null, "alias without blob reads as absent")
            val (k, created) = core.createIfAbsent("fx-orphan", key(51))
            need(created && k.contentEquals(key(51)), "create reuses the orphan alias and publishes")
            need(core.read("fx-orphan")!!.contentEquals(key(51)), "new blob opens under the reused alias")
        }
        "threads" -> {
            val results = java.util.concurrent.ConcurrentHashMap<Int, Pair<ByteArray, Boolean>>()
            val errs = java.util.concurrent.atomic.AtomicInteger()
            val start = java.util.concurrent.CountDownLatch(1)
            val ts = (1..6).map { i -> Thread { start.await(); try { results[i] = androidWrappingKeyCore(ctx).createIfAbsent("fx-threads", key(60 + i)) } catch (e: Throwable) { errs.incrementAndGet() } }.also { it.start() } }
            start.countDown(); ts.forEach { it.join(30_000) }
            need(errs.get() == 0 && results.size == 6, "6 threads, separate core instances, all finished without failure")
            need(results.values.count { it.second } == 1, "exactly one creator")
            need(results.values.map { it.first.toList() }.distinct().size == 1, "every thread holds the same key")
            need(core.read("fx-threads")!!.contentEquals(results.values.first().first), "stored key equals the winner")
        }
        "race-procs" -> {
            ctx.noBackupFilesDir.listFiles()?.filter { it.name.startsWith("fx-wk-race") }?.forEach { it.delete() }
            val t0 = System.currentTimeMillis() + 2_000
            for (c in listOf(RaceService1::class.java, RaceService2::class.java, RaceService3::class.java))
                ctx.startService(Intent(ctx, c).putExtra("t0", t0))
            val lines = (1..3).map { waitFor(stateFile(ctx, "race-$it.txt"), 60_000) }
            need(lines.all { it != null }, "3 separate OS processes reported (${lines.map { it ?: "none" }})")
            need(lines.none { it!!.startsWith("FAILED") }, "all process results valid (${lines})")
            need(lines.count { it!!.contains("created=true") } == 1, "exactly one process created the key")
            need(lines.map { it!!.substringBefore(" created") }.distinct().size == 1, "all processes saw the same key")
            val stored = core.read(RACE_NS)
            need(stored != null && lines[0]!!.startsWith("key=${sha16(stored)}"), "this process reads the winner's key")
        }
        "crash-start" -> {
            wipe(CRASH_NS)
            stateFile(ctx, "crash-ready.txt").delete()
            ctx.startService(Intent(ctx, CrashService::class.java))
            val pid = waitFor(stateFile(ctx, "crash-ready.txt"), 60_000)
            need(pid != null && pid.toIntOrNull() != null, "service blocked after fsync of temp file, before rename (pid $pid)")
            need(keyDir.listFiles().orEmpty().any { it.name.startsWith("$CRASH_NS.tmp-") }, "temp file exists, blob does not")
            need(!blob(CRASH_NS).exists() && hasAlias(CRASH_NS), "alias generated, no blob published")
            android.os.Process.killProcess(pid!!.toInt())
            Thread.sleep(1500)
            need(true, "service process killed with SIGKILL mid-create")
        }
        "crash-recover" -> {
            need(core.read(CRASH_NS) == null, "after the kill, read is absent (not an error)")
            val (k, created) = core.createIfAbsent(CRASH_NS, key(70))
            need(created && k.contentEquals(key(70)), "create succeeds after the crashed create and reuses the alias")
            need(keyDir.listFiles().orEmpty().none { it.name.startsWith("$CRASH_NS.tmp-") }, "stale temp file swept by the create")
            need(core.read(CRASH_NS)!!.contentEquals(key(70)), "key readable")
        }
        "delete" -> {
            core.createIfAbsent("fx-del", key(80))
            core.delete("fx-del")
            need(!blob("fx-del").exists() && !hasAlias("fx-del") && core.read("fx-del") == null, "blob and alias both gone")
            core.delete("fx-del")
            need(true, "deleting again (absent) is success")
        }
        "cleanup" -> {
            wipe("fx-main", "fx-dup", "fx-lost", "fx-corrupt", "fx-orphan", "fx-threads", RACE_NS, CRASH_NS, "fx-del")
            ctx.noBackupFilesDir.listFiles()?.filter { it.name.startsWith("fx-wk-") }?.forEach { it.delete() }
            need(listOf("fx-main", "fx-dup", "fx-lost", "fx-corrupt", "fx-orphan", "fx-threads", RACE_NS, CRASH_NS, "fx-del").none { hasAlias(it) || blob(it).exists() }, "all synthetic state removed")
        }
        else -> throw FixtureFailure("unknown phase")
        }
        say("END phase=$phase oks=$oks")
    }
}
