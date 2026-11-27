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
