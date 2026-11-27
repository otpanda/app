package org.otpanda.documentimport

import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.concurrent.Executor

/**
 * Flutter-free and Android-free core of the Android import file picker.
 *
 * The user picks one document (ACTION_OPEN_DOCUMENT, done by the host). This core reads it as strict UTF-8 text, at most
 * [MAX_BYTES] bytes, and hands the text back once. It never logs, never writes the bytes anywhere, never keeps a persistable
 * URI grant, and zeroes its byte and char buffers. The returned String cannot be erased (JVM and Dart strings are immutable).
 */
const val MAX_BYTES = 2 * 1024 * 1024

sealed class ReadOutcome {
    data class Text(val text: String) : ReadOutcome()
    /** More than [MAX_BYTES] bytes. */
    object TooLarge : ReadOutcome()
    /** Not well formed UTF-8, or contains NUL (a binary file). */
    object NotText : ReadOutcome()
    object Cancelled : ReadOutcome()
    /** Could not open or read. No cause is kept: provider errors can name the file. */
    object Failed : ReadOutcome()
}

/** Lets another thread stop a blocked read: cancel() closes the stream, which unblocks read() with an IOException. */
class CancelToken {
    @Volatile var cancelled = false
        private set
    @Volatile private var closeable: Closeable? = null

    fun attach(c: Closeable) {
        closeable = c
        if (cancelled) close()
    }

    fun cancel() {
        cancelled = true
        close()
    }

    private fun close() {
        try { closeable?.close() } catch (_: Throwable) {}
    }
}

private val BOM = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte())

/**
 * Reads [open]'s stream fully (bounded) and decodes it strictly. Always closes the stream. A leading UTF-8 byte order mark is
 * dropped (Windows tools write one; the Dart detector needs the first real character). Overlong forms, surrogates and
 * truncated sequences are rejected, never replaced.
 */
fun readStrictUtf8(
    open: () -> InputStream?,
    token: CancelToken,
    max: Int = MAX_BYTES,
    onAllocate: ((ByteArray) -> Unit)? = null, // test hook: lets a test check the buffer is zeroed afterwards
): ReadOutcome {
    var stream: InputStream? = null
    var buf: ByteArray? = null
    var chars: CharBuffer? = null
    try {
        if (token.cancelled) return ReadOutcome.Cancelled
        stream = try { open() } catch (_: Throwable) { null } ?: return if (token.cancelled) ReadOutcome.Cancelled else ReadOutcome.Failed
        token.attach(stream)
        val b = ByteArray(max + 1).also { buf = it; onAllocate?.invoke(it) }
        var n = 0
        while (true) {
            if (token.cancelled) return ReadOutcome.Cancelled
            val r = try {
                stream.read(b, n, b.size - n)
            } catch (_: IOException) {
                return if (token.cancelled) ReadOutcome.Cancelled else ReadOutcome.Failed
            } catch (_: Throwable) {
                return if (token.cancelled) ReadOutcome.Cancelled else ReadOutcome.Failed
            }
            if (r < 0) break
            n += r
            if (n > max) return ReadOutcome.TooLarge
        }
        if (token.cancelled) return ReadOutcome.Cancelled
        var start = 0
        if (n >= 3 && b[0] == BOM[0] && b[1] == BOM[1] && b[2] == BOM[2]) start = 3
        val decoder = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        val out = try {
            decoder.decode(ByteBuffer.wrap(b, start, n - start))
        } catch (_: CharacterCodingException) {
            return ReadOutcome.NotText
        }
        chars = out
        for (i in 0 until out.remaining()) if (out.get(out.position() + i) == '\u0000') return ReadOutcome.NotText
        return ReadOutcome.Text(out.toString())
    } finally {
        buf?.fill(0)
        chars?.let { c -> if (c.hasArray()) c.array().fill('\u0000') }
        try { stream?.close() } catch (_: Throwable) {}
    }
}

/** Where a result goes. Exactly one of these is called, once, per begin(). */
interface ImportReply {
    fun text(value: String)
    /** The user backed out, or the request was cancelled or its screen went away. */
    fun cancelled()
    /** [code]: tooLarge | notText | unreadable | busy | unavailable. Never a message, name or path. */
    fun error(code: String)
}

/**
 * One import at a time. The host supplies [launch] (starts the system picker; false if it cannot) and a [worker] for the
 * blocking read. Results from a cancelled or superseded attempt are dropped, so a late read can never reach a newer caller.
 */
class ImportSession(private val launch: () -> Boolean, private val worker: Executor, private val post: (Runnable) -> Unit) {
    private val lock = Any()
    private var reply: ImportReply? = null
    private var generation = 0L
    private var token: CancelToken? = null
    private var reading = false
    // True from a successful launch until the system picker's result (selection or back-out) is delivered. The picker UI
    // cannot be closed, so cancel() leaves this set: a new begin() is refused as busy until the old result drains, which
    // means a result can only ever belong to the one picker that is open (the host uses a single request code).
    private var pickerOpen = false

    fun begin(r: ImportReply) {
        val gen: Long
        synchronized(lock) {
            if (reply != null || pickerOpen) { post { r.error("busy") }; return }
            reply = r
            pickerOpen = true
            gen = ++generation
        }
        val started = try { launch() } catch (_: Throwable) { false }
        if (!started) {
            synchronized(lock) { if (gen == generation) pickerOpen = false }
            finish(gen) { it.error("unavailable") }
        }
    }

    /**
     * The picker returned. [open] is null when the user backed out or gave no document. Ignored (never reads) unless a request
     * is waiting for it, so a result that arrives after cancel() or detach() opens nothing.
     */
    fun onPicked(open: (() -> InputStream?)?) {
        val gen: Long
        val t = CancelToken()
        synchronized(lock) {
            if (!pickerOpen) return
            pickerOpen = false
            if (reply == null || reading) return
            if (open == null) { gen = generation } else { reading = true; token = t; gen = generation }
        }
        if (open == null) { finish(gen) { it.cancelled() }; return }
        worker.execute {
            val outcome = try { readStrictUtf8(open, t) } catch (_: Throwable) { ReadOutcome.Failed }
            finish(gen) { r ->
                when (outcome) {
                    is ReadOutcome.Text -> r.text(outcome.text)
                    ReadOutcome.TooLarge -> r.error("tooLarge")
                    ReadOutcome.NotText -> r.error("notText")
                    ReadOutcome.Cancelled -> r.cancelled()
                    ReadOutcome.Failed -> r.error("unreadable")
                }
            }
        }
    }

    /** Dart asked to stop, or the activity went away for good: stop any read, answer cancelled, accept no later result. */
    fun cancel() {
        val r: ImportReply?
        val t: CancelToken?
        synchronized(lock) {
            r = reply; t = token
            reply = null; token = null; reading = false
            generation++
        }
        t?.cancel()
        if (r != null) post { r.cancelled() }
    }

    /**
     * The activity or engine is gone for good (not a pause or a picker-induced background): no result can ever arrive, so also
     * forget the outstanding picker. Answers cancelled to any waiting request.
     */
    fun retire() {
        cancel()
        synchronized(lock) { pickerOpen = false }
    }

    private fun finish(gen: Long, call: (ImportReply) -> Unit) {
        val r: ImportReply
        synchronized(lock) {
            if (gen != generation) return
            r = reply ?: return
            reply = null; token = null; reading = false
        }
        post { call(r) }
    }

    /** For tests and the host: true while a request is waiting for a picker result or a read. */
    fun active(): Boolean = synchronized(lock) { reply != null }

    /** For tests: true while a system picker launched by this session has not delivered its result. */
    fun pickerOutstanding(): Boolean = synchronized(lock) { pickerOpen }
}
