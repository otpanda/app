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

/** Durable record of picker launches whose result has not been seen yet. Holds request codes only, never file data. */
interface CodeStore {
    /** The saved codes: empty when nothing was ever saved, null when the record exists but cannot be read or is corrupt. */
    fun load(): IntArray?
    /** Durably replaces the record before returning true (flush and atomic replace). False means nothing may rely on it. */
    fun save(codes: IntArray): Boolean
}

/** Flushes a directory's entries to disk (JVM). */
fun syncDirectoryNio(dir: java.io.File): Boolean = try {
    java.nio.channels.FileChannel.open(dir.toPath(), java.nio.file.StandardOpenOption.READ).use { it.force(true) }
    true
} catch (_: Exception) { false }

/**
 * [CodeStore] in one small file inside [dir] (the host passes the app's noBackup directory). Contents are the format tag and
 * decimal codes, nothing else. Saves write a temporary file, flush it to disk, then rename over the record, so a crash leaves
 * the old record or the new one; the directory is flushed after the rename, and a failed flush makes the save report false (the
 * caller then does not launch). Any other content makes [load] return null.
 */
class FileCodeStore(
    private val dir: java.io.File,
    /** Flushes the directory entry so the rename survives a crash. Default is java.nio; the Android host passes Os.fsync. */
    private val syncDir: (java.io.File) -> Boolean = ::syncDirectoryNio,
) : CodeStore {
    private val file = java.io.File(dir, NAME)
    private val tmp = java.io.File(dir, "$NAME.tmp")

    override fun load(): IntArray? {
        if (!file.exists()) return IntArray(0)
        return try {
            val lines = file.readText(Charsets.US_ASCII).split('\n')
            if (lines.firstOrNull() != TAG || lines.last() != "") return null
            lines.subList(1, lines.size - 1).map { if (!it.matches(NUMBER)) return null; it.toInt() }.toIntArray()
        } catch (_: Exception) { null }
    }

    override fun save(codes: IntArray): Boolean = try {
        dir.mkdirs()
        java.io.FileOutputStream(tmp).use { out ->
            out.write((TAG + "\n" + codes.joinToString("") { "$it\n" }).toByteArray(Charsets.US_ASCII))
            out.fd.sync()
        }
        tmp.renameTo(file) && syncDir(dir)
    } catch (_: Exception) { false }

    companion object {
        const val NAME = "import-picker-codes"
        private const val TAG = "otpanda-import-picker-codes-1"
        private val NUMBER = Regex("[0-9]{1,5}")
    }
}

/**
 * Attributes a system-picker result to the launch that asked for it, across engine recreation AND caller process death.
 *
 * Android keeps the system picker alive when the app's process dies and later delivers its result, with the original request
 * code, to a recreated caller in a new process. Per-process counters would restart and could alias that stale result, so the
 * set of codes that may still have a result in flight is stored durably:
 *  - [issue] picks a code not in the set, adds it and saves BEFORE the launch (fails closed with [NONE] if it cannot save,
 *    cannot read an existing record, or every code in the block is possibly in flight);
 *  - [release] removes a code only when its result has been seen (delivered, whether used or dropped) or the launch failed;
 *  - a code is therefore never given to a new launch while an older launch that used it may still deliver a result.
 * A launch whose result never comes (caller task destroyed) keeps its code reserved; the block is 1024 codes inside the lower
 * 16 bits (the legacy Activity request-code limit), and clearing app data resets it. One instance per process, shared by every
 * controller, so engine recreation sees the same set.
 */
class PickerRequests(private val store: CodeStore, private val size: Int = SIZE) {
    /** Who may consume a result. */
    enum class Claim { MINE, OTHER, ORPHAN }

    private val lock = Any()
    private var inFlight: MutableSet<Int>? = null
    private var unreadable = false
    private var cursor = 0
    // In-memory only: which live controller launched a code. A reserved code with no live owner is an orphan (left by a retired
    // controller or a dead process), and only orphans may be consumed by someone else.
    private val owners = HashMap<Int, Any>()

    private fun loaded(): MutableSet<Int>? {
        inFlight?.let { return it }
        if (unreadable) return null
        val saved = store.load()
        if (saved == null || saved.any { it < 0 || it >= size }) { unreadable = true; return null }
        return saved.toMutableSet().also { inFlight = it }
    }

    /** A code reserved durably for [owner], or [NONE]. */
    fun issue(owner: Any): Int = synchronized(lock) {
        val set = loaded() ?: return NONE
        for (step in 0 until size) {
            val n = (cursor + step) % size
            if (n in set) continue
            set.add(n)
            if (!store.save(set.toIntArray())) { set.remove(n); return NONE }
            cursor = (n + 1) % size
            owners[BASE + n] = owner
            return BASE + n
        }
        NONE
    }

    /** Who may consume a result for [code]: [owner] itself, another live controller (hands off), or nobody (orphan). */
    fun claim(code: Int, owner: Any): Claim = synchronized(lock) {
        val o = owners[code]
        when { o == null -> Claim.ORPHAN; o === owner -> Claim.MINE; else -> Claim.OTHER }
    }

    /** [owner] is gone: its launches stay reserved (their pickers may still answer) but become orphans. */
    fun abandon(owner: Any) = synchronized(lock) { owners.values.removeAll { it === owner } }

    /**
     * The launch for [code] is over (result seen, or it never started). Frees the code only if the durable record was updated;
     * if the save fails the code stays reserved in memory too, so it cannot be reused while disk still holds it. True if freed.
     */
    fun release(code: Int): Boolean = synchronized(lock) {
        val set = loaded() ?: return false
        if (code < BASE || code >= BASE + size || (code - BASE) !in set) return true
        val next = set.toMutableSet().also { it.remove(code - BASE) }
        if (!store.save(next.toIntArray())) return false
        set.remove(code - BASE); owners.remove(code)
        true
    }

    /** True when [code] is in this feature's block, whether or not it is in flight. */
    fun owns(code: Int): Boolean = code >= BASE && code < BASE + size

    fun inFlightCount(): Int = synchronized(lock) { inFlight?.size ?: -1 }

    companion object {
        /** Reserved block 0x7800..0x7BFF: below 0x10000, 1024 codes. */
        const val BASE = 0x7800
        const val SIZE = 0x0400
        const val NONE = -1
    }
}

/**
 * The host's decision logic without Android types: launch with a durable per-launch request code, route results by code.
 * [startActivity] returns false if the picker cannot be started. A result for any code but this controller's current launch is
 * dropped unread, then its code is freed.
 */
class ImportController(
    private val startActivity: (Int) -> Boolean,
    worker: Executor,
    post: (Runnable) -> Unit,
    private val requests: PickerRequests,
) {
    @Volatile private var current = PickerRequests.NONE
    private val session = ImportSession({
        val code = requests.issue(this)
        val ok = code != PickerRequests.NONE && startActivity(code)
        if (ok) current = code else if (code != PickerRequests.NONE) requests.release(code)
        ok
    }, worker, post)

    fun begin(r: ImportReply) = session.begin(r)
    fun cancel() = session.cancel()
    /** Engine or activity gone for good: the launch's result can no longer reach this controller, so it becomes an orphan. */
    fun retire() { session.retire(); current = PickerRequests.NONE; requests.abandon(this) }
    fun active(): Boolean = session.active()

    /**
     * Returns true when the code was consumed. False means leave it to someone else: a foreign code, or a code that another
     * live controller launched. Orphans (no live owner) are dropped unread and freed. Only this controller's current launch
     * is delivered.
     */
    fun onResult(code: Int, open: (() -> InputStream?)?): Boolean {
        if (!requests.owns(code)) return false
        return when (requests.claim(code, this)) {
            PickerRequests.Claim.OTHER -> false
            PickerRequests.Claim.ORPHAN -> { requests.release(code); true }
            PickerRequests.Claim.MINE -> {
                if (code == current) { current = PickerRequests.NONE; requests.release(code); session.onPicked(open) }
                else requests.release(code)
                true
            }
        }
    }
}
