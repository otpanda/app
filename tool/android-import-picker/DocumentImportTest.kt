package org.otpanda.documentimport

import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

private var checks = 0
private fun check(ok: Boolean, what: String) { checks++; if (!ok) throw AssertionError("FAIL: $what") }

/** Counts closes. */
private open class Tracked(bytes: ByteArray) : ByteArrayInputStream(bytes) {
    val closes = AtomicInteger()
    override fun close() { closes.incrementAndGet(); super.close() }
}

/** Blocks in read() until closed, like a slow cloud provider. */
private class Blocking : InputStream() {
    val started = CountDownLatch(1)
    val closes = AtomicInteger()
    @Volatile private var closed = false
    override fun read(): Int = throw UnsupportedOperationException()
    override fun read(b: ByteArray, off: Int, len: Int): Int {
        started.countDown()
        while (!closed) Thread.sleep(2)
        throw IOException("closed")
    }
    override fun close() { closes.incrementAndGet(); closed = true }
}

private class Failing(val after: ByteArray) : Tracked(after) {
    override fun read(b: ByteArray, off: Int, len: Int): Int {
        val r = super.read(b, off, len)
        if (r < 0) throw IOException("provider error naming /secret/file.json")
        return r
    }
}

private class Trickle(bytes: ByteArray) : Tracked(bytes) {
    override fun read(b: ByteArray, off: Int, len: Int): Int = super.read(b, off, minOf(len, 1))
}

private fun read(bytes: ByteArray, max: Int = MAX_BYTES, token: CancelToken = CancelToken(), s: Tracked = Tracked(bytes)): Pair<ReadOutcome, Tracked> =
    readStrictUtf8({ s }, token, max) to s

private fun text(o: ReadOutcome) = (o as? ReadOutcome.Text)?.text

private class Log : ImportReply {
    val events = java.util.Collections.synchronizedList(mutableListOf<String>())
    val done = CountDownLatch(1)
    override fun text(value: String) { events.add("text:$value"); done.countDown() }
    override fun cancelled() { events.add("cancelled"); done.countDown() }
    override fun error(code: String) { events.add("error:$code"); done.countDown() }
}

private val inline = Executor { it.run() }

fun main() {
    // ---- reader ----
    check(text(read("hello".toByteArray()).first) == "hello", "plain")
    check(text(read(byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()) + "{\"a\":1}".toByteArray()).first) == "{\"a\":1}", "BOM dropped")
    check(text(read("é日本😀".toByteArray()).first) == "é日本😀", "multibyte and astral")
    check(text(read(ByteArray(0)).first) == "", "empty file is empty text")
    check(text(read(ByteArray(16) { 'a'.code.toByte() }, max = 16).first) == "a".repeat(16), "exactly max")
    check(read(ByteArray(17) { 'a'.code.toByte() }, max = 16).first == ReadOutcome.TooLarge, "max+1")
    run {
        val exact = ByteArray(MAX_BYTES) { 'x'.code.toByte() }
        check(text(read(exact).first)?.length == MAX_BYTES, "exactly 2 MiB reads")
        check(read(ByteArray(MAX_BYTES + 1) { 'x'.code.toByte() }).first == ReadOutcome.TooLarge, "2 MiB + 1 is too large")
    }
    check(text(read("{}".toByteArray(), s = Trickle("{}".toByteArray())).first) == "{}", "one byte reads")
    val bad = listOf(
        "lone continuation" to byteArrayOf(0x80.toByte()),
        "truncated 3 byte" to byteArrayOf('a'.code.toByte(), 0xE6.toByte(), 0x97.toByte()),
        "overlong NUL" to byteArrayOf(0xC0.toByte(), 0x80.toByte()),
        "overlong slash" to byteArrayOf(0xC0.toByte(), 0xAF.toByte()),
        "encoded surrogate" to byteArrayOf(0xED.toByte(), 0xA0.toByte(), 0x80.toByte()),
        "5 byte form" to byteArrayOf(0xF8.toByte(), 0x88.toByte(), 0x80.toByte(), 0x80.toByte(), 0x80.toByte()),
        "above U+10FFFF" to byteArrayOf(0xF4.toByte(), 0x90.toByte(), 0x80.toByte(), 0x80.toByte()),
        "UTF-16 LE text" to "ab".toByteArray(Charsets.UTF_16LE),
        "NUL" to byteArrayOf('a'.code.toByte(), 0, 'b'.code.toByte()),
    )
    for ((name, bytes) in bad) check(read(bytes).first == ReadOutcome.NotText, "rejects $name")

    // stream closed on every path
    for ((name, o) in listOf(
        "ok" to read("x".toByteArray()),
        "too large" to read(ByteArray(40), max = 8),
        "not text" to read(byteArrayOf(0x80.toByte())),
    )) check(o.second.closes.get() >= 1, "closes on $name")
    run {
        val f = Failing("abc".toByteArray())
        check(readStrictUtf8({ f }, CancelToken()) == ReadOutcome.Failed, "IOException is Failed")
        check(f.closes.get() >= 1, "closes after IOException")
    }
    check(readStrictUtf8({ null }, CancelToken()) == ReadOutcome.Failed, "null stream is Failed")
    check(readStrictUtf8({ throw SecurityException("x") }, CancelToken()) == ReadOutcome.Failed, "open throwing is Failed")

    // buffer is zeroed after success and after failure
    run {
        var captured: ByteArray? = null
        readStrictUtf8({ Tracked("secret-key-data".toByteArray()) }, CancelToken(), 64, { captured = it })
        check(captured!!.all { it == 0.toByte() }, "buffer zeroed after success")
        captured = null
        readStrictUtf8({ Tracked(byteArrayOf(0x80.toByte(), 1, 2)) }, CancelToken(), 64, { captured = it })
        check(captured!!.all { it == 0.toByte() }, "buffer zeroed after rejection")
    }

    // cancel before read: open never called
    run {
        val t = CancelToken(); t.cancel()
        var opened = false
        check(readStrictUtf8({ opened = true; Tracked(ByteArray(1)) }, t) == ReadOutcome.Cancelled, "cancel before read")
        check(!opened, "stream never opened after cancel")
    }
    // cancel during a blocked read
    run {
        val b = Blocking(); val t = CancelToken()
        val out = java.util.concurrent.atomic.AtomicReference<ReadOutcome>()
        val th = Thread { out.set(readStrictUtf8({ b }, t)) }
        th.start()
        check(b.started.await(2, TimeUnit.SECONDS), "blocked read started")
        t.cancel()
        th.join(2000)
        check(!th.isAlive && out.get() == ReadOutcome.Cancelled, "cancel unblocks a stuck provider")
        check(b.closes.get() >= 1, "stuck stream closed")
    }

    // ---- session ----
    val post = { r: Runnable -> r.run() }
    run {
        var launches = 0
        val s = ImportSession({ launches++; true }, inline, post)
        val l = Log(); s.begin(l)
        check(launches == 1 && s.active(), "begin launches the picker")
        val l2 = Log(); s.begin(l2)
        check(l2.events == listOf("error:busy") && launches == 1, "second begin is busy and does not launch")
        s.onPicked { Tracked("hi".toByteArray()) }
        check(l.events == listOf("text:hi") && !s.active(), "text delivered once, session free")
        s.onPicked { Tracked("again".toByteArray()) }
        check(l.events == listOf("text:hi"), "a second result opens nothing")
        val l3 = Log(); s.begin(l3); s.onPicked(null)
        check(l3.events == listOf("cancelled"), "user backed out")
    }
    run {
        val s = ImportSession({ false }, inline, post)
        val l = Log(); s.begin(l)
        check(l.events == listOf("error:unavailable") && !s.active(), "launch false is unavailable and frees the session")
        val s2 = ImportSession({ throw IllegalStateException() }, inline, post)
        val l2 = Log(); s2.begin(l2)
        check(l2.events == listOf("error:unavailable") && !s2.active(), "launch throwing is unavailable")
    }
    for ((name, bytes, code) in listOf(
        Triple("big", ByteArray(MAX_BYTES + 1) { 'a'.code.toByte() }, "tooLarge"),
        Triple("binary", byteArrayOf(0x80.toByte()), "notText"),
    )) {
        val s = ImportSession({ true }, inline, post)
        val l = Log(); s.begin(l); s.onPicked { Tracked(bytes) }
        check(l.events == listOf("error:$code"), "session maps $name to $code")
    }
    run {
        val s = ImportSession({ true }, inline, post)
        val l = Log(); s.begin(l); s.onPicked { Failing("x".toByteArray()) }
        check(l.events == listOf("error:unreadable"), "provider error is unreadable with no detail")
    }
    // cancel while waiting for the picker
    run {
        var opened = false
        val s = ImportSession({ true }, inline, post)
        val l = Log(); s.begin(l); s.cancel()
        check(l.events == listOf("cancelled") && !s.active(), "cancel while picker is open")
        s.onPicked { opened = true; Tracked("late".toByteArray()) }
        check(!opened && l.events == listOf("cancelled"), "late picker result opens nothing")
        s.cancel()
        check(l.events == listOf("cancelled"), "cancel is idempotent")
    }
    // cancel during a blocked read; a new request must not receive the stale result
    run {
        val pool = Executors.newSingleThreadExecutor()
        val s = ImportSession({ true }, pool, post)
        val b = Blocking(); val l = Log()
        s.begin(l); s.onPicked { b }
        check(b.started.await(2, TimeUnit.SECONDS), "session read started")
        s.cancel()
        check(l.events == listOf("cancelled"), "cancel answers at once")
        val pool2 = Executors.newSingleThreadExecutor()
        pool.shutdown(); pool.awaitTermination(2, TimeUnit.SECONDS)
        check(b.closes.get() >= 1, "stuck stream closed by cancel")
        check(l.events == listOf("cancelled"), "the aborted read added no second reply")
        pool2.shutdown()
        val s2 = ImportSession({ true }, inline, post)
        val first = Log(); s2.begin(first); s2.cancel(); s2.onPicked(null)
        val second = Log(); s2.begin(second); s2.onPicked { Tracked("new".toByteArray()) }
        check(first.events == listOf("cancelled") && second.events == listOf("text:new"), "new request unaffected by old one")
    }
    // old picker still open after cancel: a new begin is refused, and the old selection is never given to a new request
    run {
        var opened = 0
        var launches = 0
        val s = ImportSession({ launches++; true }, inline, post)
        val old = Log(); s.begin(old); s.cancel()
        check(old.events == listOf("cancelled") && !s.active() && s.pickerOutstanding(), "cancel keeps the picker outstanding")
        val fresh = Log(); s.begin(fresh)
        check(fresh.events == listOf("error:busy") && launches == 1, "begin while old picker open is busy and launches nothing")
        s.onPicked { opened++; Tracked("old-selection".toByteArray()) }
        check(opened == 0 && !s.pickerOutstanding(), "old selection after cancel and refused begin is dropped unread")
        check(fresh.events == listOf("error:busy") && old.events == listOf("cancelled"), "no reply reached the refused or cancelled caller")
        val next = Log(); s.begin(next)
        check(launches == 2 && s.pickerOutstanding(), "new begin launches once the old result drained")
        s.onPicked { Tracked("new-selection".toByteArray()) }
        check(next.events == listOf("text:new-selection") && !s.pickerOutstanding(), "new selection goes to the new request")
    }
    // back-out of the old picker also drains it
    run {
        val s = ImportSession({ true }, inline, post)
        val old = Log(); s.begin(old); s.cancel(); s.onPicked(null)
        val next = Log(); s.begin(next)
        check(old.events == listOf("cancelled") && next.events.isEmpty() && s.active(), "back-out of old picker drains it")
    }
    // launch failure leaves nothing outstanding; retire (real teardown) forgets the picker
    run {
        val s = ImportSession({ false }, inline, post)
        val l = Log(); s.begin(l)
        check(l.events == listOf("error:unavailable") && !s.pickerOutstanding(), "failed launch is not outstanding")
        var launches = 0
        val s2 = ImportSession({ launches++; true }, inline, post)
        val a = Log(); s2.begin(a); s2.retire()
        check(a.events == listOf("cancelled") && !s2.pickerOutstanding(), "retire answers cancelled and forgets the picker")
        val b = Log(); s2.begin(b)
        check(launches == 2 && b.events.isEmpty(), "begin works after retire")
        // lifecycle: the app pausing for the picker is not a call into the session, so a waiting request survives it
        check(s2.active() && s2.pickerOutstanding(), "waiting request is untouched by backgrounding")
        s2.onPicked { Tracked("after-background".toByteArray()) }
        check(b.events == listOf("text:after-background"), "selection after the app returns from the picker is delivered")
    }
    // Controller and durable allocator: engine recreation, process death, rotation, normal return.
    run {
        class Disk : CodeStore {
            var saved: IntArray? = IntArray(0); var failSave = false; var saves = 0
            override fun load(): IntArray? = saved?.copyOf()
            override fun save(codes: IntArray): Boolean { if (failSave) return false; saved = codes.copyOf(); saves++; return true }
        }
        val disk = Disk()
        val codes = ArrayList<Int>()
        // "process": one PickerRequests over the disk; controllers share it (engine recreation inside one process)
        fun proc(size: Int = PickerRequests.SIZE) = PickerRequests(disk, size)
        fun ctl(r: PickerRequests, ok: Boolean = true) = ImportController({ codes.add(it); ok }, inline, post, r)
        val p1 = proc()
        // normal return
        val a = ctl(p1); val la = Log(); a.begin(la)
        check(disk.saved!!.size == 1, "code saved durably before the launch")
        check(a.onResult(codes.last(), { Tracked("ok".toByteArray()) }) && la.events == listOf("text:ok"), "normal picker return delivers once")
        check(p1.inFlightCount() == 0 && disk.saved!!.isEmpty(), "code freed once its result was seen")
        a.onResult(codes.last(), { Tracked("again".toByteArray()) })
        check(la.events == listOf("text:ok"), "a second result for the same launch is not delivered")
        check(!a.onResult(1234, null) && !a.onResult(PickerRequests.BASE - 1, null) && !a.onResult(PickerRequests.BASE + PickerRequests.SIZE, null), "foreign codes not consumed")
        check(PickerRequests.BASE >= 0 && PickerRequests.BASE + PickerRequests.SIZE <= 0x10000, "block fits the lower 16 bits")
        // rotation: same controller, result arrives later with the launch's code
        val r = ctl(p1); val lr = Log(); r.begin(lr); val rc = codes.last()
        check(lr.events.isEmpty() && r.active(), "rotation keeps the request waiting")
        check(r.onResult(rc, { Tracked("rotated".toByteArray()) }) && lr.events == listOf("text:rotated"), "result after rotation delivered")
        // engine recreation inside one process: old controller retires, new one begins, OLD result arrives
        val oldEngine = ctl(p1); val lo = Log(); oldEngine.begin(lo); val oldCode = codes.last()
        oldEngine.retire()
        check(lo.events == listOf("cancelled") && p1.inFlightCount() == 1, "retired engine's request answered cancelled, its code still reserved")
        val newEngine = ctl(p1); val ln = Log(); newEngine.begin(ln); val newCode = codes.last()
        check(oldCode != newCode, "new launch has a different code while the old picker may still answer")
        var opened = 0
        check(newEngine.onResult(oldCode, { opened++; Tracked("OLD".toByteArray()) }), "old result consumed")
        check(opened == 0 && ln.events.isEmpty() && newEngine.active() && p1.inFlightCount() == 1, "old picker result after recreation never reaches the new request, and its code is freed")
        check(newEngine.onResult(newCode, { Tracked("NEW".toByteArray()) }) && ln.events == listOf("text:NEW") && p1.inFlightCount() == 0, "the new picker's own result is delivered")
        // PROCESS DEATH with the picker alive: new process, fresh in-memory state, same disk
        val dead = ctl(p1); val ld = Log(); dead.begin(ld); val deadCode = codes.last()
        val p2 = proc()                                  // new process: cursor restarts at 0
        val reborn = ctl(p2); val lrb = Log(); reborn.begin(lrb); val newCode2 = codes.last()
        check(newCode2 != deadCode, "after process death a new launch never reuses a code that may still answer")
        check(reborn.onResult(deadCode, { opened++; Tracked("STALE".toByteArray()) }) && opened == 0 && lrb.events.isEmpty(), "old picker's result after process death is dropped unread and does not reach the new request")
        check(reborn.onResult(newCode2, { Tracked("FRESH".toByteArray()) }) && lrb.events == listOf("text:FRESH"), "new request still gets its own result")
        check(disk.saved!!.isEmpty(), "no codes left reserved")
        // old result reaches a fresh process with no request: dropped, code freed
        val q1 = proc(); val dead2 = ctl(q1); dead2.begin(Log()); val c2 = codes.last()
        val idle = ctl(proc())
        check(idle.onResult(c2, { opened++; Tracked("x".toByteArray()) }) && opened == 0 && disk.saved!!.isEmpty(), "old result to an idle new process dropped unread")
        // cancel then begin: busy, old result dropped
        val c = ctl(proc()); val lc = Log(); c.begin(lc); val cc = codes.last(); c.cancel()
        val lb = Log(); c.begin(lb)
        check(lb.events == listOf("error:busy") && codes.last() == cc, "begin after cancel with old picker open is busy, no new launch")
        check(c.onResult(cc, { opened++; Tracked("c".toByteArray()) }) && opened == 0 && lc.events == listOf("cancelled") && disk.saved!!.isEmpty(), "old result after cancel dropped and freed")
        // failed launch frees its code
        val f = ctl(proc(), false); val lf = Log(); f.begin(lf)
        check(lf.events == listOf("error:unavailable") && disk.saved!!.isEmpty(), "failed launch reports unavailable and frees its code")
        // save failure fails closed with no launch
        val before = codes.size
        disk.failSave = true
        val sf = ctl(proc()); val lsf = Log(); sf.begin(lsf)
        check(lsf.events == listOf("error:unavailable") && codes.size == before && disk.saved!!.isEmpty(), "unsaved code means no launch")
        disk.failSave = false
        // unreadable record fails closed and never treats it as empty
        disk.saved = null
        val un = ctl(proc()); val lu = Log(); un.begin(lu)
        check(lu.events == listOf("error:unavailable") && codes.size == before, "corrupt record fails closed")
        disk.saved = intArrayOf(PickerRequests.SIZE + 5)
        val un2 = ctl(proc()); val lu2 = Log(); un2.begin(lu2)
        check(lu2.events == listOf("error:unavailable") && codes.size == before, "out-of-range record fails closed")
        disk.saved = IntArray(0)
        // exhaustion: every code possibly in flight fails closed; abandoned codes persist across processes
        val small = 3
        val sp = proc(small); val s1 = ctl(sp); s1.begin(Log()); s1.retire()
        val s2 = ctl(sp); s2.begin(Log()); s2.retire()
        val s3 = ctl(proc(small)); s3.begin(Log()); s3.retire()
        val used = codes.takeLast(3)
        check(used.toSet().size == 3 && disk.saved!!.size == 3, "three launches reserve three distinct codes, durably")
        val s4 = ctl(proc(small)); val l4 = Log(); val n4 = codes.size; s4.begin(l4)
        check(l4.events == listOf("error:unavailable") && codes.size == n4, "exhausted block fails closed with no launch")
        val s5 = ctl(proc(small)); check(s5.onResult(used[1], null) && disk.saved!!.size == 2, "a seen result frees only its own code")
        val l5 = Log(); s5.begin(l5)
        check(codes.last() == used[1], "a freed code can be reused only after its result was seen")
        // multi-controller: a live controller never takes another live controller's result
        run {
            disk.saved = IntArray(0)
            val sp2 = proc(); val owner = ctl(sp2); val other = ctl(sp2)
            val lo2 = Log(); owner.begin(lo2); val oc = codes.last()
            var o2 = 0
            check(!other.onResult(oc, { o2++; Tracked("steal".toByteArray()) }) && o2 == 0 && sp2.inFlightCount() == 1, "another live controller does not consume or free a live launch")
            check(owner.onResult(oc, { Tracked("mine".toByteArray()) }) && lo2.events == listOf("text:mine") && sp2.inFlightCount() == 0, "the owner still gets its result")
            // once the owner retires its launch is an orphan and anyone may drop it
            val lo3 = Log(); owner.begin(lo3); val oc3 = codes.last(); owner.retire()
            check(other.onResult(oc3, { o2++; Tracked("orphan".toByteArray()) }) && o2 == 0 && sp2.inFlightCount() == 0, "an orphaned launch is dropped unread and freed by a live controller")
        }
        // failed durable release keeps the code reserved (memory and disk agree), so it cannot be reused
        run {
            disk.saved = IntArray(0)
            val sp2 = proc(3); val c = ctl(sp2); val l = Log(); c.begin(l); val code1 = codes.last()
            disk.failSave = true
            check(c.onResult(code1, { Tracked("ok".toByteArray()) }) && l.events == listOf("text:ok"), "result is still delivered when the release cannot be saved")
            check(sp2.inFlightCount() == 1 && disk.saved!!.size == 1, "reservation retained in memory and on disk")
            disk.failSave = false
            val seen = HashSet<Int>()
            repeat(2) { val x = ctl(sp2); x.begin(Log()); seen.add(codes.last()); x.retire() }
            check(code1 !in seen && sp2.inFlightCount() == 3, "a code whose release failed is not handed out again")
            val y = ctl(sp2); val ly = Log(); y.begin(ly)
            check(ly.events == listOf("error:unavailable"), "block with a stuck reservation exhausts closed")
            check(sp2.release(code1) && sp2.inFlightCount() == 2 && disk.saved!!.size == 2, "a later successful release frees it")
            disk.saved = IntArray(0)
        }
        // concurrent issue through one shared instance: distinct codes
        val cd = Disk(); val shared = PickerRequests(cd, 200); val seenCodes = java.util.concurrent.ConcurrentHashMap.newKeySet<Int>()
        val ts = (1..8).map { Thread { repeat(40) { val x = shared.issue(Any()); if (x != PickerRequests.NONE) check(seenCodes.add(x), "duplicate code") } } }
        ts.forEach { it.start() }; ts.forEach { it.join() }
        check(seenCodes.size == 200 && cd.saved!!.size == 200, "concurrent issuers get 200 distinct durable codes and stop")
    }
    // FileCodeStore: durable record format, atomic replace, strict load
    run {
        val d = java.nio.file.Files.createTempDirectory("codes").toFile()
        val s = FileCodeStore(d)
        check(s.load()!!.isEmpty(), "missing record is empty")
        check(s.save(intArrayOf(5, 17, 1023)) && s.load()!!.toList() == listOf(5, 17, 1023), "record round trips")
        check(s.save(IntArray(0)) && s.load()!!.isEmpty(), "empty record round trips")
        s.save(intArrayOf(9))
        java.io.File(d, FileCodeStore.NAME + ".tmp").writeText("garbage from an interrupted write")
        check(FileCodeStore(d).load()!!.toList() == listOf(9), "an interrupted temp file never replaces the record")
        val rec = java.io.File(d, FileCodeStore.NAME)
        for ((name, body) in listOf("no tag" to "5\n", "wrong tag" to "x\n5\n", "no trailing newline" to "otpanda-import-picker-codes-1\n5",
                "non-number" to "otpanda-import-picker-codes-1\nabc\n", "negative" to "otpanda-import-picker-codes-1\n-1\n", "empty line" to "otpanda-import-picker-codes-1\n\n")) {
            rec.writeText(body)
            check(FileCodeStore(d).load() == null, "corrupt record ($name) is unreadable, not empty")
        }
        check(rec.readBytes().all { it >= 0 }, "record is plain ASCII")
        s.save(intArrayOf(3)); check(rec.readText().none { it.code > 127 } && rec.readText().lines().size == 3, "record holds only the tag and codes")
        // directory flush happens after the rename, and a failed flush fails the save
        val d2 = java.nio.file.Files.createTempDirectory("codes2").toFile()
        var sawRenamed = false; var syncs = 0
        val ok = FileCodeStore(d2, { sawRenamed = java.io.File(d2, FileCodeStore.NAME).exists() && !java.io.File(d2, FileCodeStore.NAME + ".tmp").exists(); syncs++; true })
        check(ok.save(intArrayOf(4)) && sawRenamed && syncs == 1, "directory is flushed after the rename")
        val bad = FileCodeStore(d2, { false })
        check(!bad.save(intArrayOf(4, 6)), "a failed directory flush reports the save as failed")
        check(syncDirectoryNio(d2) && !syncDirectoryNio(java.io.File(d2, "missing")), "default directory flush works on a real directory and fails on a missing one")
        d2.deleteRecursively()
        d.deleteRecursively()
    }
    // a slow read finishing after cancel and after a new begin is dropped
    run {
        val gate = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(2)
        val s = ImportSession({ true }, pool, post)
        val old = Log(); s.begin(old)
        s.onPicked { gate.await(2, TimeUnit.SECONDS); Tracked("old".toByteArray()) }
        s.cancel()
        val fresh = Log(); s.begin(fresh); s.onPicked { Tracked("fresh".toByteArray()) }
        fresh.done.await(2, TimeUnit.SECONDS)
        gate.countDown()
        Thread.sleep(100)
        check(old.events == listOf("cancelled"), "old request only ever got cancelled")
        check(fresh.events == listOf("text:fresh"), "stale text never reaches the new caller")
        pool.shutdown()
    }

    println("PASS $checks checks")
}
