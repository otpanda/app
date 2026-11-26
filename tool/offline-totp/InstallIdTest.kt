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
        chk(d.listFiles()!!.map { it.name } == listOf("install-id")) // no temp files left
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
        chk(InstallIdFile(d, RecSync()).read() == got[0].first && d.listFiles()!!.map { it.name } == listOf("install-id"))
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
        chk(!File(d, "install-id").exists() && (d.list()?.toList() ?: emptyList()).isEmpty(), "nothing published, no temp left")
    }
    // 9. a failed confirmation AFTER the link: no id is returned, the file stays in place, and neither read nor create bypasses the confirmation until a sync succeeds
    run {
        val d = File(root, "post"); val s = InstallIdFile(d, RecSync(3))
        chk(failKind { s.createIfAbsent(A) } == InstallIdFailure.Kind.UNAVAILABLE)
        chk(File(d, "install-id").readText() == A && d.list()!!.toList() == listOf("install-id"), "link left in place, never deleted")
        chk(failKind { s.read() } == InstallIdFailure.Kind.UNAVAILABLE && failKind { s.createIfAbsent(B) } == InstallIdFailure.Kind.UNAVAILABLE, "same object does not return the unconfirmed id")
        chk(failKind { InstallIdFile(d, RecSync(1)).read() } == InstallIdFailure.Kind.UNAVAILABLE && failKind { InstallIdFile(d, RecSync(1)).createIfAbsent(B) } == InstallIdFailure.Kind.UNAVAILABLE, "a fresh object also needs a confirmation")
        val ok = RecSync(); val s2 = InstallIdFile(d, ok)
        chk(s2.createIfAbsent(B) == (A to false) && ok.calls.size == 2, "existing winner returned only after base and dir were synced")
        chk(s2.read() == A && ok.calls.size == 2, "confirmed once per store object")
    }
    // 10. a failed temp file sync publishes nothing
    run {
        val d = File(root, "fsyncfail"); val s = InstallIdFile(d, RecSync(), fileSync = { throw java.io.IOException("injected") })
        chk(failKind { s.createIfAbsent(A) } == InstallIdFailure.Kind.UNAVAILABLE && d.list()!!.isEmpty())
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
    root.deleteRecursively()
    println("PASS install id store: create-only, winner kept, malformed or unreadable never overwritten, concurrent create has one winner (JVM filesystem, not Android)")
}
