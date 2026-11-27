package org.otpanda.totp

import java.io.File

/** TEST ONLY child process for InstallIdTest: args dir id mode. Modes: normal, hang-after-temp (prints READY after the temp file fsync hook and blocks), hang-after-rename (prints READY when the
 * post-publish directory confirmation starts and blocks). The parent kills it with SIGKILL. DirSync here is a FAKE: this proves lock and rename behavior across processes, not durability. */
fun main(args: Array<String>) {
    val (dir, id, mode) = args
    var calls = 0
    val sync = DirSync { _ -> calls++; if (mode == "hang-after-rename" && calls == 3) { println("READY"); System.out.flush(); Thread.sleep(Long.MAX_VALUE) } }
    val file = InstallIdFile(File(dir), sync, fileSync = { s -> s.fd.sync(); if (mode == "hang-after-temp") { println("READY"); System.out.flush(); Thread.sleep(Long.MAX_VALUE) } })
    // like a caller would: retry a bounded UNAVAILABLE (lock wait expired); report it plainly when it persists
    var tries = if (mode == "once") 1 else 8
    while (true) {
        try { val r = file.createIfAbsent(id); println(r.first + " created=" + r.second); return }
        catch (e: InstallIdFailure) { if (--tries <= 0) { println("FAILED " + e.kind.name); return } ; Thread.sleep(50) }
    }
}
