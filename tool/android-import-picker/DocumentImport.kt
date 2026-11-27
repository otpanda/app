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

/** Durable record of how many request codes this install has ever issued. Numbers only, never file data. */
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
 * Attributes a system-picker result to the launch that asked for it, across engine recreation and caller process death.
 *
 * Staging design, chosen for qualification and deliberately simple: request codes are issued from a reserved block of [SIZE]
 * values (0x7800..0x7BFF, inside the lower 16 bits) by a MONOTONIC counter that is saved durably BEFORE the launch and is never
 * reset, wrapped, recycled or lowered. A code is never handed out twice for the life of the app's data, whatever happened to
 * its launch (result delivered, dropped, failed, abandoned, process killed). So a late or duplicate result can never carry the
 * code of a different launch, and nothing here depends on Android delivering results exactly once.
 *
 * Limit, stated plainly: the block holds 1024 launches. When it is used up, [issue] returns [NONE] and picking reports
 * "unavailable" until the app's data is cleared. A save failure or an unreadable record also fails closed. There is no silent reset.
 *
 * Owner routing is in memory: a live controller consumes only the result of its own current launch; a code issued by another live
 * controller is left alone ([Claim.OTHER]); any other issued code (retired controller, earlier process) is dropped unread.
 */
class PickerRequests(private val store: CodeStore, private val size: Int = SIZE) {
    enum class Claim { MINE, OTHER, ORPHAN }

    private val lock = Any()
    private var next = -1                       // -1: record not loaded yet
    private var unreadable = false
    private val owners = HashMap<Int, Any>()    // in-memory only: code -> live controller that launched it

    /** The record is a single number: how many codes were ever issued. An empty record (never written) means 0. */
    private fun loaded(): Boolean {
        if (next >= 0) return true
        if (unreadable) return false
        val saved = store.load()
        if (saved == null || saved.size > 1 || (saved.size == 1 && (saved[0] < 0 || saved[0] > size))) { unreadable = true; return false }
        next = if (saved.isEmpty()) 0 else saved[0]
        return true
    }

    /** A fresh, never-before-issued code reserved durably for [owner], or [NONE] (exhausted, unreadable record or save failure). */
    fun issue(owner: Any): Int = synchronized(lock) {
        if (!loaded() || next >= size) return NONE
        if (!store.save(intArrayOf(next + 1))) return NONE
        val code = BASE + next
        next++
        owners[code] = owner
        code
    }

    fun claim(code: Int, owner: Any): Claim = synchronized(lock) {
        val o = owners[code]
        when { o == null -> Claim.ORPHAN; o === owner -> Claim.MINE; else -> Claim.OTHER }
    }

    /** [owner] is gone: its launches' pickers may still answer, and those results are dropped unread. */
    fun abandon(owner: Any) = synchronized(lock) { owners.values.removeAll { it === owner } }

    /** [owner]'s launch got its result. The code stays spent. */
    fun settle(code: Int, owner: Any) = synchronized(lock) { if (owners[code] === owner) owners.remove(code) }

    /** True when [code] is in this feature's block, whether or not it was ever issued. */
    fun owns(code: Int): Boolean = code >= BASE && code < BASE + size

    /** For tests: codes issued so far (-1 while unloaded). */
    fun issuedCount(): Int = synchronized(lock) { next }

    companion object {
        /** Reserved block 0x7800..0x7BFF: below 0x10000, 1024 launches per install. */
        const val BASE = 0x7800
        const val SIZE = 0x0400
        const val NONE = -1
    }
}

/**
 * The host's decision logic without Android types: launch with a durable, never-reused request code and route results by code.
 * [startActivity] returns false if the picker cannot be started (that code stays spent). Only this controller's current launch
 * is delivered; every other code is dropped unread, or left to its live owner.
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
        if (ok) current = code
        ok
    }, worker, post)

    fun begin(r: ImportReply) = session.begin(r)
    fun cancel() = session.cancel()
    /** Engine or activity gone for good: the launch's result can no longer reach this controller. */
    fun retire() { session.retire(); current = PickerRequests.NONE; requests.abandon(this) }
    fun active(): Boolean = session.active()

    /** Returns true when the code was consumed. False leaves it to others: a foreign code, or another live controller's launch. */
    fun onResult(code: Int, open: (() -> InputStream?)?): Boolean {
        if (!requests.owns(code)) return false
        return when (requests.claim(code, this)) {
            PickerRequests.Claim.OTHER -> false
            PickerRequests.Claim.ORPHAN -> true
            PickerRequests.Claim.MINE -> {
                if (code == current) { current = PickerRequests.NONE; requests.settle(code, this); session.onPicked(open) }
                else requests.settle(code, this)
                true
            }
        }
    }
}
