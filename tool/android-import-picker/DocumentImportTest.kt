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
    // Controller: per-launch request codes, engine recreation, rotation, normal return.
    run {
        val counter = AtomicInteger()
        val codes = ArrayList<Int>()
        fun ctl(ok: Boolean = true) = ImportController({ codes.add(it); ok }, inline, post, counter)
        // normal return
        val a = ctl(); val la = Log(); a.begin(la)
        check(a.onResult(codes.last(), { Tracked("ok".toByteArray()) }) && la.events == listOf("text:ok"), "normal picker return delivers once")
        a.onResult(codes.last(), { Tracked("again".toByteArray()) })
        check(la.events == listOf("text:ok"), "a second result for the same launch is not delivered")
        // foreign request codes are left to other listeners
        check(!a.onResult(1234, null) && !a.onResult(PickerRequests.BASE - 1, null) && !a.onResult(PickerRequests.BASE + PickerRequests.SIZE, null), "foreign codes not consumed")
        // rotation: same controller, result arrives later with the launch's code
        val r = ctl(); val lr = Log(); r.begin(lr); val rc = codes.last()
        check(lr.events.isEmpty() && r.active(), "rotation keeps the request waiting")
        check(r.onResult(rc, { Tracked("rotated".toByteArray()) }) && lr.events == listOf("text:rotated"), "result after rotation delivered")
        // permanent recreation: old engine retired, new engine begins its own picker, then the OLD picker's result arrives
        val oldEngine = ctl(); val lo = Log(); oldEngine.begin(lo); val oldCode = codes.last()
        oldEngine.retire()
        check(lo.events == listOf("cancelled"), "retired engine's request answered cancelled")
        val newEngine = ctl(); val ln = Log(); newEngine.begin(ln); val newCode = codes.last()
        check(oldCode != newCode, "new launch has a different request code than the old one")
        var opened = 0
        check(newEngine.onResult(oldCode, { opened++; Tracked("OLD".toByteArray()) }), "old result consumed")
        check(opened == 0 && ln.events.isEmpty() && newEngine.active(), "old picker result after recreation never reaches the new request")
        check(newEngine.onResult(newCode, { Tracked("NEW".toByteArray()) }) && ln.events == listOf("text:NEW"), "the new picker's own result is delivered")
        // old result reaches a fresh engine that has not begun anything
        val old2 = ctl(); old2.begin(Log()); val c2 = codes.last(); old2.retire()
        val idle = ctl()
        check(idle.onResult(c2, { opened++; Tracked("x".toByteArray()) }) && opened == 0, "old result to an idle engine dropped unread")
        // cancel then new begin on same engine: busy, and the old result still cannot reach anyone
        val c = ctl(); val lc = Log(); c.begin(lc); val cc = codes.last(); c.cancel()
        val lb = Log(); c.begin(lb)
        check(lb.events == listOf("error:busy") && codes.last() == cc, "begin after cancel with old picker open is busy, no new launch")
        check(c.onResult(cc, { opened++; Tracked("c".toByteArray()) }) && opened == 0 && lc.events == listOf("cancelled"), "old result after cancel dropped")
        // failed launch forgets the code
        val f = ctl(false); val lf = Log(); f.begin(lf)
        val failedCode = codes.last()
        check(lf.events == listOf("error:unavailable"), "failed launch reports unavailable")
        f.onResult(failedCode, { Tracked("z".toByteArray()) })
        check(lf.events == listOf("error:unavailable"), "result for a failed launch is dropped")
        check(PickerRequests.BASE >= 0 && PickerRequests.BASE + PickerRequests.SIZE <= 0x10000, "block fits the lower 16 bits")
        // exhaustion fails closed and never reuses a code, even after retire and a new controller
        val small = AtomicInteger(); val used = ArrayList<Int>()
        fun sc() = ImportController({ used.add(it); true }, inline, post, small, 3)
        val e1 = sc(); val l1 = Log(); e1.begin(l1); e1.onResult(used.last(), null)
        val l2 = Log(); e1.begin(l2); e1.cancel(); e1.retire()
        val e2 = sc(); val l3 = Log(); e2.begin(l3)
        check(used == listOf(PickerRequests.BASE, PickerRequests.BASE + 1, PickerRequests.BASE + 2), "codes advance, none reused across controllers")
        e2.onResult(used.last(), { Tracked("last".toByteArray()) })
        val e3 = sc(); val l4 = Log(); e3.begin(l4)
        check(l4.events == listOf("error:unavailable") && used.size == 3 && !e3.active(), "exhausted block fails closed with no launch")
        val before = l4.events.size
        check(!e3.onResult(PickerRequests.BASE + 3, { Tracked("q".toByteArray()) }) && l4.events.size == before, "code beyond the block is not owned")
        for (c in used) { var o = 0; e3.onResult(c, { o++; Tracked("stale".toByteArray()) }); check(o == 0, "stale code $c cannot reach a later request") }
        // counter never moves past the block, even under repeated exhausted begins
        repeat(5) { sc().begin(Log()) }
        check(small.get() == 3, "counter stops at the block size")
        // concurrent issue: all distinct, none beyond the block
        val big = AtomicInteger(); val seenCodes = java.util.concurrent.ConcurrentHashMap.newKeySet<Int>()
        val ts = (1..8).map { Thread { val r = PickerRequests(big, 200); repeat(40) { val c = r.issue(); if (c != PickerRequests.NONE) check(seenCodes.add(c), "duplicate code") } } }
        ts.forEach { it.start() }; ts.forEach { it.join() }
        check(seenCodes.size == 200 && big.get() == 200, "concurrent issuers get 200 distinct codes and stop")
        val seen = codes.toSet().size
        check(seen == codes.size, "every launch in the process used a distinct code")
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
