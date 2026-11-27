package org.otpanda.wrappingkey

import java.io.File

/** TEST ONLY child process for WrappingKeyTest: args dir ns hexbyte mode. Modes: normal, hang-after-temp (prints READY after the temp file fsync and blocks; the parent kills it). */
fun main(args: Array<String>) {
    val (dir, ns, hex, mode) = args
    val ks = FakeKeystore()
    val core = WrappingKeyCore(File(dir), WkDirSync { _ -> }, ks::wrapper,
        fileSync = { s -> s.fd.sync(); if (mode == "hang-after-temp") { println("READY"); System.out.flush(); Thread.sleep(Long.MAX_VALUE) } })
    var tries = 8
    val cand = ByteArray(32) { hex.toInt(16).toByte() }
    while (true) {
        try { val r = core.createIfAbsent(ns, cand); println(r.first.joinToString("") { "%02x".format(it) } + " created=" + r.second); return }
        catch (e: WrappingKeyFailure) { if (--tries <= 0) { println("FAILED " + e.kind.name + " unknown=" + e.outcomeUnknown); return }; Thread.sleep(50) }
    }
}
