package org.otpanda.wrappingkey

import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors

private fun chk(c: Boolean, m: String = "check failed") { if (!c) throw IllegalStateException(m) }
private fun fail(w: () -> Any?): WrappingKeyFailure? = try { w(); null } catch (e: WrappingKeyFailure) { e }
private fun key(b: Int) = ByteArray(32) { b.toByte() }
private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
private val U = WrappingKeyFailure.Kind.UNAVAILABLE
private val L = WrappingKeyFailure.Kind.LOCKED
private val M = WrappingKeyFailure.Kind.MISSING_ALIAS
private val C = WrappingKeyFailure.Kind.CORRUPT

fun main() {
    val root = java.nio.file.Files.createTempDirectory("wrapkey").toFile()
    var n = 0
    fun fresh() = File(root, "d${n++}").also { it.mkdirs() }.let { File(it, "store") } // dir is ONE level beneath an existing base
    fun core(d: File, ks: FakeKeystore, sync: WkDirSync = RecordingSync(), unlocked: () -> Boolean = { true }) = WrappingKeyCore(d, sync, ks::wrapper, unlocked)
    val NS = "inst-1"
    val A = key(0xA1); val B = key(0xB2)

    // 1. absent, create, winner kept, a new object (a restart) sees it; only blob and lock remain
    run {
        val d = fresh(); val ks = FakeKeystore(); val s = core(d, ks)
        chk(s.read(NS) == null)
        val r = s.createIfAbsent(NS, A); chk(r.first.contentEquals(A) && r.second)
        chk(s.read(NS)!!.contentEquals(A))
        val r2 = s.createIfAbsent(NS, B); chk(r2.first.contentEquals(A) && !r2.second, "winner kept")
        chk(core(d, ks).read(NS)!!.contentEquals(A))
        chk(d.listFiles()!!.map { it.name }.toSet() == setOf("$NS.key", "$NS.lock"))
        chk(File(d, "$NS.key").length() == 61L)
        chk(!File(d, "$NS.key").readBytes().drop(13).take(32).toByteArray().contentEquals(A), "blob does not hold the plain key")
        chk(ks.generateCount == 1)
    }
    // 2. invalid input never touches anything
    run {
        val d = fresh(); val ks = FakeKeystore(); val s = core(d, ks)
        for (bad in listOf("", "a b", "x".repeat(65), "é", "../x", "a/b")) { chk(fail { s.read(bad) }?.kind == U, "read $bad"); chk(fail { s.createIfAbsent(bad, A) }?.kind == U); chk(fail { s.delete(bad) }?.kind == U) }
        for (bad in listOf(0, 16, 31, 33, 64)) chk(fail { s.createIfAbsent(NS, ByteArray(bad)) }?.let { it.kind == U && !it.outcomeUnknown } == true)
        chk(!d.exists() && ks.generateCount == 0)
    }
    // 3. damaged existing blobs: corrupt, never absent, never replaced or deleted
    run {
        val tampers = mapOf<String, (ByteArray) -> ByteArray>(
            "tag flip" to { b -> b.also { it[60] = (it[60].toInt() xor 1).toByte() } }, "ciphertext flip" to { b -> b.also { it[20] = (it[20].toInt() xor 1).toByte() } },
            "truncated" to { b -> b.copyOf(60) }, "extended" to { b -> b + 0 }, "empty" to { _ -> ByteArray(0) }, "version 2" to { b -> b.also { it[0] = 2 } }, "iv flip" to { b -> b.also { it[3] = (it[3].toInt() xor 1).toByte() } })
        for ((name, f) in tampers) {
            val d = fresh(); val ks = FakeKeystore(); core(d, ks).createIfAbsent(NS, A)
            val file = File(d, "$NS.key"); val bad = f(file.readBytes()); file.writeBytes(bad)
            val s = core(d, ks)
            chk(fail { s.read(NS) }?.kind == C, "read $name"); chk(fail { s.createIfAbsent(NS, B) }?.let { it.kind == C && !it.outcomeUnknown } == true, "create $name")
            chk(file.readBytes().contentEquals(bad), "untouched $name"); chk(ks.generateCount == 1, "no regeneration $name")
        }
        val d = fresh(); val ks = FakeKeystore(); val s = core(d, ks); File(d, "$NS.key").mkdirs()
        chk(fail { s.read(NS) }?.kind == C && fail { s.createIfAbsent(NS, A) }?.kind == C && File(d, "$NS.key").isDirectory, "directory in place of blob is corrupt")
        val d2 = fresh(); d2.mkdirs(); val target = File(d2.parentFile, "elsewhere"); target.writeBytes(ByteArray(61))
        val linked = try { java.nio.file.Files.createSymbolicLink(File(d2, "$NS.key").toPath(), target.toPath()); true } catch (_: Exception) { false }
        if (linked) chk(fail { core(d2, ks).read(NS) }?.kind == C, "symlink is corrupt, not followed") else println("SKIPPED symlink check")
    }
    // 4. missing alias: the blob exists, the Keystore key is gone. Never recreate, replace or purge.
    run {
        val d = fresh(); val ks = FakeKeystore(); val s = core(d, ks); s.createIfAbsent(NS, A)
        val before = File(d, "$NS.key").readBytes()
        ks.present.remove(NS); ks.removed.add(NS)
        chk(fail { s.read(NS) }?.let { it.kind == M && !it.outcomeUnknown } == true)
        chk(fail { s.createIfAbsent(NS, B) }?.let { it.kind == M && !it.outcomeUnknown } == true)
        chk(File(d, "$NS.key").readBytes().contentEquals(before) && ks.generateCount == 1 && NS !in ks.present, "no new key, blob untouched")
    }
    // 5. locked: before first unlock nothing is read as absent and nothing is written
    run {
        val d = fresh(); val ks = FakeKeystore(); var unlocked = false; val s = core(d, ks, unlocked = { unlocked })
        chk(fail { s.read(NS) }?.let { it.kind == L && !it.outcomeUnknown } == true); chk(fail { s.createIfAbsent(NS, A) }?.let { it.kind == L && !it.outcomeUnknown } == true); chk(fail { s.delete(NS) }?.let { it.kind == L && !it.outcomeUnknown } == true)
        chk(!d.exists() && ks.generateCount == 0)
        unlocked = true; chk(s.read(NS) == null && s.createIfAbsent(NS, A).second)
        // storage that locks mid-call reports LOCKED, known not applied when it failed before publish
        var calls = 0; val d2 = fresh(); val s2 = WrappingKeyCore(d2, RecordingSync(failFrom = 1), ks::wrapper, { ++calls <= 1 })
        chk(fail { s2.createIfAbsent("other", A) }?.let { it.kind == L && !it.outcomeUnknown } == true, "mid-call lock")
        val ksl = FakeKeystore(); ksl.failEnsure = WrappingKeyFailure(L)
        chk(fail { core(fresh(), ksl).createIfAbsent(NS, A) }?.let { it.kind == L && !it.outcomeUnknown } == true, "keystore locked")
    }
    // 6. an alias without a blob (a crashed create) is absence, and the next create reuses the alias
    run {
        val d = fresh(); val ks = FakeKeystore(); ks.present.add(NS); val s = core(d, ks)
        chk(s.read(NS) == null); chk(s.createIfAbsent(NS, A).second && ks.generateCount == 0, "alias reused, not regenerated")
    }
    // 7. a failing wrap publishes nothing and leaves no temp file
    run {
        val d = fresh(); val ks = FakeKeystore(); ks.failWrap = WrappingKeyFailure(U)
        chk(fail { core(d, ks).createIfAbsent(NS, A) }?.let { it.kind == U && !it.outcomeUnknown } == true)
        chk(d.listFiles()!!.none { it.name.endsWith(".key") || it.name.endsWith(".part") })
        ks.failWrap = null; ks.failEnsure = WrappingKeyFailure(U)
        chk(fail { core(d, ks).createIfAbsent(NS, A) }?.let { it.kind == U && !it.outcomeUnknown } == true)
    }
    // 8. durability failures: before the rename known not applied, after it unknown; a published blob is never deleted and a later read returns it
    for (from in 1..4) {
        val d = fresh(); val ks = FakeKeystore(); val rec = RecordingSync(failFrom = from)
        val f = fail { core(d, ks, rec).createIfAbsent(NS, A) }
        chk(f != null && f.kind == U, "sync fail $from")
        if (from <= 2) { chk(!f!!.outcomeUnknown && !File(d, "$NS.key").exists(), "pre-publish $from") }
        else { chk(f!!.outcomeUnknown && File(d, "$NS.key").exists(), "post-publish $from"); chk(core(d, ks).read(NS)!!.contentEquals(A), "winner readable after failed confirm") }
        chk(rec.blobPresent.take(2).none { it } && (from < 4 || rec.blobPresent[3]), "order $from")
    }
    // 8b. a failed first confirm of an EXISTING blob fails closed with no key
    run {
        val d = fresh(); val ks = FakeKeystore(); core(d, ks).createIfAbsent(NS, A)
        chk(fail { core(d, ks, RecordingSync(failFrom = 1)).read(NS) }?.kind == U, "unconfirmed existing blob is not returned")
    }
    // 9. concurrent create over separate store objects: one creator, one key
    run {
        val d = fresh(); val ks = FakeKeystore(); val k = 16; val pool = Executors.newFixedThreadPool(k); val gate = CountDownLatch(1)
        val res = (0 until k).map { i -> pool.submit<Pair<ByteArray, Boolean>> { gate.await(); core(d, ks).createIfAbsent(NS, if (i % 2 == 0) A else B) } }
        gate.countDown(); val got = res.map { it.get() }; pool.shutdown()
        chk(got.map { hex(it.first) }.toSet().size == 1 && got.count { it.second } == 1, "one winner")
        chk(core(d, ks).read(NS)!!.contentEquals(got[0].first) && d.listFiles()!!.map { it.name }.toSet() == setOf("$NS.key", "$NS.lock") && ks.generateCount == 1)
    }
    // 10. cross-process: simultaneous creators, and a SIGKILL after the temp write
    run {
        val d = fresh(); val cp = System.getProperty("java.class.path")
        fun child(h: String, mode: String) = ProcessBuilder("java", "-cp", cp, "org.otpanda.wrappingkey.WrappingKeyChildKt", d.path, NS, h, mode).redirectErrorStream(true).start()
        val procs = (1..4).map { child("0${it}", "normal") }
        val outs = procs.map { it.inputStream.bufferedReader().readText().trim().also { _ -> it.waitFor() } }
        chk(outs.none { it.startsWith("FAILED") }, "children: $outs")
        chk(outs.map { it.substringBefore(' ') }.toSet().size == 1 && outs.count { it.endsWith("created=true") } == 1, "one key, one creator: $outs")
        val d2 = fresh(); val hang = ProcessBuilder("java", "-cp", cp, "org.otpanda.wrappingkey.WrappingKeyChildKt", d2.path, NS, "07", "hang-after-temp").redirectErrorStream(true).start()
        chk(hang.inputStream.bufferedReader().readLine() == "READY"); hang.destroyForcibly().waitFor()
        chk(d2.listFiles()!!.any { it.name.endsWith(".part") } && !File(d2, "$NS.key").exists(), "killed after temp: stale temp, no blob")
        val ks = FakeKeystore(); val s = core(d2, ks)
        chk(s.read(NS) == null && s.createIfAbsent(NS, A).second, "OS dropped the lock; a new creator succeeds")
        chk(d2.listFiles()!!.map { it.name }.toSet() == setOf("$NS.key", "$NS.lock"), "stale temp swept")
    }
    // 11. delete is explicit and complete; absent is success; a corrupt blob can be purged; failures are outcome-unknown
    run {
        val d = fresh(); val ks = FakeKeystore(); val s = core(d, ks); s.createIfAbsent(NS, A)
        s.delete(NS); chk(s.read(NS) == null && NS !in ks.present && !File(d, "$NS.key").exists()); s.delete(NS)
        s.createIfAbsent(NS, A); File(d, "$NS.key").writeBytes(ByteArray(5)); s.delete(NS); chk(!File(d, "$NS.key").exists(), "corrupt blob purged on explicit delete")
        s.createIfAbsent(NS, B); ks.failDelete = WrappingKeyFailure(U)
        chk(fail { s.delete(NS) }?.let { it.kind == U && it.outcomeUnknown } == true); ks.failDelete = null
        chk(s.read(NS) == null, "blob already gone; the orphan alias remains and is reused")
        File(d, "dirblob.key").mkdirs(); chk(fail { s.delete("dirblob") }?.let { it.kind == C && !it.outcomeUnknown } == true && File(d, "dirblob.key").isDirectory)
    }
    // 12. namespaces are independent
    run { val d = fresh(); val ks = FakeKeystore(); val s = core(d, ks); s.createIfAbsent("a", A); s.createIfAbsent("b", B); chk(s.read("a")!!.contentEquals(A) && s.read("b")!!.contentEquals(B)); s.delete("a"); chk(s.read("a") == null && s.read("b")!!.contentEquals(B)) }
    // 13. channel handler: exact arguments, wire codes, zeroed candidate
    run {
        val d = fresh(); val ks = FakeKeystore(); val h = WrappingKeyChannelHandler(core(d, ks))
        chk(h.handle("wrappingKeyRead", mapOf("namespace" to NS)) == WkReply.Ok(mapOf("key" to null)))
        val cand = key(0x5A); val c = h.handle("wrappingKeyCreate", mapOf("namespace" to NS, "key" to cand)) as WkReply.Ok
        chk((c.value as Map<*, *>)["created"] == true && (c.value as Map<*, *>)["key"].let { it is ByteArray && it.contentEquals(key(0x5A)) }); chk(cand.all { it == 0.toByte() }, "candidate zeroed")
        val r = h.handle("wrappingKeyRead", mapOf("namespace" to NS)) as WkReply.Ok; chk(((r.value as Map<*, *>)["key"] as ByteArray).contentEquals(key(0x5A)))
        val c2 = h.handle("wrappingKeyCreate", mapOf("namespace" to NS, "key" to key(1))) as WkReply.Ok; chk((c2.value as Map<*, *>)["created"] == false)
        for (bad in listOf<Any?>(null, emptyMap<String, Any>(), mapOf("namespace" to 1), mapOf("namespace" to NS, "extra" to 1), mapOf("namespace" to NS, "key" to "str"), mapOf("key" to key(1))))
            chk(h.handle("wrappingKeyCreate", bad) == WkReply.Err("unavailable", false), "bad create args $bad")
        chk(h.handle("wrappingKeyRead", mapOf("namespace" to NS, "key" to key(1))) == WkReply.Err("unavailable", false))
        chk(h.handle("wrappingKeyCreate", mapOf("namespace" to NS, "key" to ByteArray(16))) == WkReply.Err("unavailable", false))
        chk(h.handle("nope", mapOf("namespace" to NS)) == WkReply.NotImplemented)
        chk(h.handle("wrappingKeyDelete", mapOf("namespace" to NS)) == WkReply.Ok(emptyMap<String, Any?>()))
        File(d, "x.key").writeBytes(ByteArray(3)); chk(h.handle("wrappingKeyRead", mapOf("namespace" to "x")) == WkReply.Err("corrupt", false))
        ks.present.add("m"); core(d, ks).createIfAbsent("m", A); ks.removed.add("m"); ks.present.remove("m")
        chk(h.handle("wrappingKeyRead", mapOf("namespace" to "m")) == WkReply.Err("missingAlias", false))
        val hl = WrappingKeyChannelHandler(core(fresh(), ks, unlocked = { false }))
        chk(hl.handle("wrappingKeyRead", mapOf("namespace" to NS)) == WkReply.Err("locked", false))
        val boom = WrappingKeyChannelHandler(WrappingKeyCore(fresh(), RecordingSync(), { throw RuntimeException("x") }))
        chk(boom.handle("wrappingKeyCreate", mapOf("namespace" to NS, "key" to key(1))) == WkReply.Err("unavailable", true), "unexpected failure in a mutation is unknown")
        chk(boom.handle("wrappingKeyRead", mapOf("namespace" to NS)) == WkReply.Ok(mapOf("key" to null)), "absent read does not need the wrapper")
    }
    // Regression: an uncertain ensureKey failure (platform exception after alias existence became uncertain) must never remove a pre-existing or orphan alias.
    run {
        val d = fresh(); val ks = FakeKeystore(); val s = core(d, ks)
        s.createIfAbsent(NS, A); File(d, "$NS.key").delete() // orphan alias: key present, no blob
        chk(ks.present.contains(NS))
        ks.failEnsure = WrappingKeyFailure(U)
        val f = fail { s.createIfAbsent(NS, B) }
        chk(f != null && f.kind == U, "uncertain ensureKey failure is unavailable")
        chk(ks.present.contains(NS) && !ks.removed.contains(NS), "alias preserved after the uncertain failure")
        chk(!File(d, "$NS.key").exists(), "no blob published")
        ks.failEnsure = null
        val r = s.createIfAbsent(NS, B); chk(r.second && r.first.contentEquals(B) && ks.generateCount == 1, "later create reuses the preserved alias, no new key generated")
    }
    println("PASS android wrapping key core, channel and process tests (JVM fakes; not Keystore evidence)")
}
