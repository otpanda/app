package org.otpanda.totp

import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors

private fun chk(c: Boolean, m: String = "check failed") { if (!c) throw IllegalStateException(m) }
/** Recording DirSync FAKE for the JVM: it proves call order and failure handling, NOT durability. */
private class RecSync(val failFrom: Int = Int.MAX_VALUE) : DirSync {
    val calls = mutableListOf<String>(); val targetPresent = mutableListOf<Boolean>()
    override fun sync(dir: File) { calls.add(dir.name); targetPresent.add(File(dir, "install-id").exists()); if (calls.size >= failFrom) throw java.io.IOException("injected") }
}
private fun failKind(w: () -> Any?): InstallIdFailure.Kind? = try { w(); null } catch (e: InstallIdFailure) { e.kind }

fun main() {
    val root = java.nio.file.Files.createTempDirectory("installid").toFile()
    fun fresh() = File(root, "d" + System.nanoTime()).also { it.mkdirs() }
    val A = "A".repeat(43); val B = "B".repeat(43)
    // 1. absent, create, winner kept, restart (new object) sees it
    run {
        val d = fresh(); val s = InstallIdFile(d, RecSync())
        chk(s.read() == null)
        chk(s.createIfAbsent(A) == (A to true) && s.read() == A)
        chk(s.createIfAbsent(B) == (A to false) && s.read() == A)
        chk(InstallIdFile(d, RecSync()).read() == A) // a new process sees the same id
        chk(d.listFiles()!!.map { it.name }.toSet() == setOf("install-id", "install-id.lock")) // lock file persists, no temp files left
    }
    // 2. invalid candidate refused and nothing written
    run {
        val d = fresh(); val s = InstallIdFile(d, RecSync())
        for (bad in listOf("", "short", "a b".repeat(10), A + "\n", "A".repeat(65), "é".repeat(30))) chk(failKind { s.createIfAbsent(bad) } == InstallIdFailure.Kind.INVALID_INPUT, "candidate $bad")
        chk(s.read() == null && !File(d, "install-id").exists())
    }
    // 3. malformed existing files are never overwritten, repaired or deleted
    for (content in listOf("", "short", A + "\n", A + A, "\u0000".repeat(43), "x".repeat(200))) {
        val d = fresh(); File(d, "install-id").writeBytes(content.toByteArray(Charsets.ISO_8859_1))
        val s = InstallIdFile(d, RecSync())
        chk(failKind { s.read() } == InstallIdFailure.Kind.UNREADABLE, "read $content")
        chk(failKind { s.createIfAbsent(B) } == InstallIdFailure.Kind.UNREADABLE, "create $content")
        chk(File(d, "install-id").readBytes().contentEquals(content.toByteArray(Charsets.ISO_8859_1)), "file untouched")
    }
    // 4. a directory where the file should be is unreadable, not absent
    run { val d = fresh(); File(d, "install-id").mkdirs(); chk(failKind { InstallIdFile(d, RecSync()).read() } == InstallIdFailure.Kind.UNREADABLE) }
    // 5. concurrent create: many threads over separate store objects on one directory (the cross-instance case): exactly one winner, all return the same id
    run {
        val d = fresh(); val n = 16; val pool = Executors.newFixedThreadPool(n); val gate = CountDownLatch(1)
        val results = (0 until n).map { i -> pool.submit<Pair<String, Boolean>> { gate.await(); InstallIdFile(d, RecSync()).createIfAbsent(if (i % 2 == 0) A else B) } }
        gate.countDown(); val got = results.map { it.get() }; pool.shutdown()
        chk(got.map { it.first }.toSet().size == 1, "one id")
        chk(got.count { it.second } == 1, "exactly one creator")
        chk(InstallIdFile(d, RecSync()).read() == got[0].first && d.listFiles()!!.map { it.name }.toSet() == setOf("install-id", "install-id.lock"))
    }
    // 6. a stale temp file from a crash before publish does not count as an id
    run { val d = fresh(); File(d, "tmp-1.part").writeText(A); val s = InstallIdFile(d, RecSync()); chk(s.read() == null && s.createIfAbsent(B) == (B to true)) }
    // 7. directory sync order: base then dir BEFORE publish, then confirmation after; the directory is created when absent
    run {
        val d = File(root, "newdir"); val r = RecSync(); val s = InstallIdFile(d, r)
        chk(s.read() == null && !d.exists() && r.calls.isEmpty(), "absent read creates and syncs nothing")
        chk(s.createIfAbsent(A) == (A to true))
        chk(r.calls.take(2) == listOf(root.name, "newdir") && r.targetPresent.take(2) == listOf(false, false), "base and dir synced before publish")
        chk(r.calls == listOf(root.name, "newdir", root.name, "newdir") && r.targetPresent[3], "confirmation after publish covers base and dir")
    }
    // 8. a failed sync before publish publishes nothing and returns no id
    for (from in 1..2) run {
        val d = File(root, "pre$from"); val s = InstallIdFile(d, RecSync(from))
        chk(failKind { s.createIfAbsent(A) } == InstallIdFailure.Kind.UNAVAILABLE)
        chk(!File(d, "install-id").exists() && (d.list()?.toList() ?: emptyList()).none { it.endsWith(".part") }, "nothing published, no temp left")
    }
    // 9. a failed confirmation AFTER the link: no id is returned, the file stays in place, and neither read nor create bypasses the confirmation until a sync succeeds
    run {
        val d = File(root, "post"); val s = InstallIdFile(d, RecSync(3))
        chk(failKind { s.createIfAbsent(A) } == InstallIdFailure.Kind.UNAVAILABLE)
        chk(File(d, "install-id").readText() == A && d.list()!!.toSet() == setOf("install-id", "install-id.lock"), "published file left in place, never deleted")
        chk(failKind { s.read() } == InstallIdFailure.Kind.UNAVAILABLE && failKind { s.createIfAbsent(B) } == InstallIdFailure.Kind.UNAVAILABLE, "same object does not return the unconfirmed id")
        chk(failKind { InstallIdFile(d, RecSync(1)).read() } == InstallIdFailure.Kind.UNAVAILABLE && failKind { InstallIdFile(d, RecSync(1)).createIfAbsent(B) } == InstallIdFailure.Kind.UNAVAILABLE, "a fresh object also needs a confirmation")
        val ok = RecSync(); val s2 = InstallIdFile(d, ok)
        chk(s2.createIfAbsent(B) == (A to false) && ok.calls.size == 2, "existing winner returned only after base and dir were synced")
        chk(s2.read() == A && ok.calls.size == 2, "confirmed once per store object")
    }
    // 10. a failed temp file sync publishes nothing
    run {
        val d = File(root, "fsyncfail"); val s = InstallIdFile(d, RecSync(), fileSync = { throw java.io.IOException("injected") })
        chk(failKind { s.createIfAbsent(A) } == InstallIdFailure.Kind.UNAVAILABLE && d.list()!!.none { it.endsWith(".part") } && !File(d, "install-id").exists())
    }
    // 11. only a definite NoSuchFile is absence: an unexaminable parent, a symlink, a non-directory parent are UNREADABLE
    run {
        val plain = File(root, "afile"); plain.writeText("x")
        chk(failKind { InstallIdFile(File(plain, "sub"), RecSync()).read() } == InstallIdFailure.Kind.UNREADABLE, "parent component is a regular file")
        val d = fresh(); File(d, "real").writeText(A); java.nio.file.Files.createSymbolicLink(File(d, "install-id").toPath(), File(d, "real").toPath())
        chk(failKind { InstallIdFile(d, RecSync()).read() } == InstallIdFailure.Kind.UNREADABLE, "symlink is not followed and not an id")
        val locked = fresh(); File(locked, "install-id").writeText(A); locked.setExecutable(false)
        val outcome = failKind { InstallIdFile(locked, RecSync()).read() }; locked.setExecutable(true)
        chk(outcome == InstallIdFailure.Kind.UNREADABLE, "unsearchable parent is UNREADABLE, never absent (uid " + System.getProperty("user.name") + ")")
        val locked2 = fresh(); locked2.setExecutable(false)
        val o2 = failKind { InstallIdFile(locked2, RecSync()).createIfAbsent(A) }; locked2.setExecutable(true)
        chk(o2 == InstallIdFailure.Kind.UNREADABLE && !File(locked2, "install-id").exists(), "create on an unsearchable parent writes nothing")
    }
    // 12. REAL processes (separate JVMs): the lock and rename give one winner across processes, and a holder killed at each point leaves a safe state
    val cp = System.getProperty("java.class.path"); val javaBin = File(System.getProperty("java.home"), "bin/java").path
    fun child(d: File, id: String, mode: String) = ProcessBuilder(javaBin, "-cp", cp, "org.otpanda.totp.InstallIdChildKt", d.path, id, mode).redirectErrorStream(true).start()
    fun lines(p: Process) = p.inputStream.bufferedReader().readText().trim().lines()
    run {
        val d = fresh(); val ids = (0 until 6).map { "P".repeat(21) + it }
        val ps = ids.map { child(d, it, "normal") }
        val res = ps.map { lines(it).last() }; ps.forEach { chk(it.waitFor() == 0, "child exit") }
        val winners = res.filter { it.endsWith(" created=true") }
        chk(winners.size == 1, "exactly one creating process: $res")
        chk(res.map { it.substringBefore(" ") }.toSet().size == 1 && InstallIdFile(d, RecSync()).read() == res[0].substringBefore(" "), "all processes agree on the winner")
    }
    for (mode in listOf("hang-after-temp", "hang-after-rename")) run {
        val d = fresh(); val p = child(d, "K".repeat(22), mode)
        val rd = p.inputStream.bufferedReader(); chk(rd.readLine() == "READY", "child reached $mode")
        // a second creator must WAIT while the holder lives (it holds the OS lock), so start it, confirm it is blocked, then kill the holder
        val waiter = child(d, "W".repeat(22), "once"); val wout = lines(waiter).last(); waiter.waitFor()
        if (mode == "hang-after-temp") chk(wout == "FAILED UNAVAILABLE", "second process fails closed (bounded lock wait) while the first holds the lock: $wout")
        else chk(wout == "K".repeat(22) + " created=false", "id already renamed: a reader or creator returns the published id without the lock: $wout")
        p.destroyForcibly(); p.waitFor()
        val waiter2 = child(d, "W".repeat(22), "normal"); val out = lines(waiter2).last(); chk(waiter2.waitFor() == 0)
        val got = InstallIdFile(d, RecSync()).read()
        if (mode == "hang-after-temp") { chk(out == "W".repeat(22) + " created=true" && got == "W".repeat(22), "killed before publish: nothing was committed, waiter created: $out") }
        else { chk(out == "K".repeat(22) + " created=false" && got == "K".repeat(22), "killed after rename: the published id is the winner: $out") }
        chk(File(d, "install-id.lock").exists(), "lock file persists")
    }
    // 13. lock path that is a symlink or directory is never opened; an in-process lock holder makes a second store fail closed after the bounded wait
    run {
        val d = fresh(); File(d, "real").writeText("x"); java.nio.file.Files.createSymbolicLink(File(d, "install-id.lock").toPath(), File(d, "real").toPath())
        chk(failKind { InstallIdFile(d, RecSync()).createIfAbsent(A) } == InstallIdFailure.Kind.UNAVAILABLE && !File(d, "install-id").exists(), "symlink lock path")
        val d2 = fresh(); File(d2, "install-id.lock").mkdirs()
        chk(failKind { InstallIdFile(d2, RecSync()).createIfAbsent(A) } == InstallIdFailure.Kind.UNAVAILABLE && !File(d2, "install-id").exists(), "directory lock path")
        val d3 = fresh(); val gate = CountDownLatch(1); val inFsync = CountDownLatch(1)
        val holder = Thread { InstallIdFile(d3, RecSync(), fileSync = { inFsync.countDown(); gate.await() }).createIfAbsent(A) }.also { it.start() }
        inFsync.await()
        val t0 = System.nanoTime()
        chk(failKind { InstallIdFile(d3, RecSync(), lockWaitMs = 200).createIfAbsent(B) } == InstallIdFailure.Kind.UNAVAILABLE && (System.nanoTime() - t0) / 1_000_000 < 3000, "second store in the same process fails closed within the bound")
        gate.countDown(); holder.join(5000)
        chk(InstallIdFile(d3, RecSync()).read() == A, "holder published, second store never replaced it")
    }
    // 14. injected winners. The hook runs at the exact point named; the winner is written by someone who does NOT take the lock. The result must be that winner, byte for byte, with no temp left.
    run {
        val W = "W".repeat(43)
        // (a) after the first read and before the locks: DirSync's first call happens in that window
        val d = fresh(); var injected = false; var tempWrites = 0
        val s = InstallIdFile(d, DirSync { _ -> if (!injected) { injected = true; File(d, "install-id").writeBytes(W.toByteArray()) } }, fileSync = { tempWrites++ })
        chk(s.createIfAbsent(A) == (W to false), "pre-lock winner returned")
        chk(File(d, "install-id").readBytes().contentEquals(W.toByteArray()) && d.list()!!.none { it.endsWith(".part") } && tempWrites == 0, "pre-lock winner byte-identical, no temp was even written")
        // (b) after the temp file is written and before the move (the pre-move re-check is the only guard against a writer that ignores the lock)
        val d2 = fresh()
        val s2 = InstallIdFile(d2, RecSync(), fileSync = { st -> st.fd.sync(); File(d2, "install-id").writeBytes(W.toByteArray()) })
        chk(s2.createIfAbsent(A) == (W to false), "pre-move winner returned")
        chk(File(d2, "install-id").readBytes().contentEquals(W.toByteArray()) && d2.list()!!.none { it.endsWith(".part") }, "pre-move winner byte-identical, no temp")
        // (c) a malformed or symlink entry appearing at the same points is UNREADABLE and untouched
        val d3 = fresh()
        val s3 = InstallIdFile(d3, RecSync(), fileSync = { st -> st.fd.sync(); File(d3, "install-id").writeText("bad") })
        chk(failKind { s3.createIfAbsent(A) } == InstallIdFailure.Kind.UNREADABLE && File(d3, "install-id").readText() == "bad" && d3.list()!!.none { it.endsWith(".part") }, "pre-move malformed entry untouched")
    }
    // 15. a failed rename: UNAVAILABLE, nothing published, locks released (a later create works at once, from the same and from another store), at most one stale temp
    run {
        val d = fresh()
        val s = InstallIdFile(d, RecSync(), fileSync = { st -> st.fd.sync(); d.setWritable(false) }, lockWaitMs = 300) // directory loses write permission before the move: the move fails
        val first = failKind { s.createIfAbsent(A) }; d.setWritable(true)
        chk(first == InstallIdFailure.Kind.UNAVAILABLE && !File(d, "install-id").exists(), "failed rename fails closed, publishes nothing (uid " + System.getProperty("user.name") + ")")
        chk(d.list()!!.count { it.endsWith(".part") } <= 1, "at most one stale temp from the failed create")
        val t0 = System.nanoTime()
        chk(InstallIdFile(d, RecSync(), lockWaitMs = 300).createIfAbsent(B) == (B to true) && (System.nanoTime() - t0) / 1_000_000 < 250, "lock was released: another store creates immediately")
        chk(File(d, "install-id").readText() == B && d.list()!!.count { it.endsWith(".part") } <= 1, "stale temp ignored, bound kept")
    }
    root.deleteRecursively()
    println("PASS install id store: create-only, winner kept, malformed or unreadable never overwritten, concurrent create has one winner (JVM filesystem, not Android)")
}
