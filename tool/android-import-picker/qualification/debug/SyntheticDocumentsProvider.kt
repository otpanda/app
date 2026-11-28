package app.otpanda.pickerfx

import android.database.Cursor
import android.database.MatrixCursor
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import android.util.Log
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Debug source set only. A synthetic DocumentsProvider the real system picker can browse. Content is fixed synthetic text.
 * Every document open is counted and logged with a fixed id (never a name, URI or content), so a run can prove that a stale
 * selection was never opened.
 */
class SyntheticDocumentsProvider : DocumentsProvider() {
    private class Doc(val id: String, val name: String, val mime: String, val size: Long, val write: (java.io.OutputStream) -> Unit)

    private val docs = listOf(
        Doc("a", "fixture-a.txt", "text/plain", 11) { it.write("synthetic-a".toByteArray()) },
        Doc("b", "fixture-b.txt", "text/plain", 11) { it.write("synthetic-b".toByteArray()) },
        Doc("bad", "fixture-bad.bin", "application/octet-stream", 3) { it.write(byteArrayOf(0xFF.toByte(), 0xFE.toByte(), 0x80.toByte())) },
        Doc("big", "fixture-big.bin", "application/octet-stream", 2L * 1024 * 1024 + 1) {
            val chunk = ByteArray(8192) { 'x'.code.toByte() }
            var left = 2L * 1024 * 1024 + 1
            while (left > 0) { val n = minOf(left, chunk.size.toLong()).toInt(); it.write(chunk, 0, n); left -= n }
        },
    )
    private val opens = ConcurrentHashMap<String, AtomicInteger>()

    override fun onCreate(): Boolean = true

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val c = MatrixCursor(projection ?: arrayOf(Root.COLUMN_ROOT_ID, Root.COLUMN_FLAGS, Root.COLUMN_TITLE, Root.COLUMN_DOCUMENT_ID, Root.COLUMN_ICON))
        c.newRow().add(Root.COLUMN_ROOT_ID, ROOT).add(Root.COLUMN_FLAGS, Root.FLAG_LOCAL_ONLY)
            .add(Root.COLUMN_TITLE, ROOT_TITLE).add(Root.COLUMN_DOCUMENT_ID, ROOT)
            .add(Root.COLUMN_ICON, android.R.drawable.ic_menu_agenda)
        return c
    }

    private fun cols(p: Array<out String>?): Array<out String> =
        p ?: arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE, Document.COLUMN_FLAGS, Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED)

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
        val c = MatrixCursor(cols(projection))
        if (documentId == ROOT) {
            c.newRow().add(Document.COLUMN_DOCUMENT_ID, ROOT).add(Document.COLUMN_DISPLAY_NAME, ROOT_TITLE)
                .add(Document.COLUMN_MIME_TYPE, Document.MIME_TYPE_DIR).add(Document.COLUMN_FLAGS, 0)
        } else {
            row(c, docs.firstOrNull { it.id == documentId } ?: throw java.io.FileNotFoundException())
        }
        return c
    }

    override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?, sortOrder: String?): Cursor {
        val c = MatrixCursor(cols(projection))
        if (parentDocumentId == ROOT) docs.forEach { row(c, it) }
        return c
    }

    private fun row(c: MatrixCursor, d: Doc) {
        c.newRow().add(Document.COLUMN_DOCUMENT_ID, d.id).add(Document.COLUMN_DISPLAY_NAME, d.name)
            .add(Document.COLUMN_MIME_TYPE, d.mime).add(Document.COLUMN_FLAGS, 0)
            .add(Document.COLUMN_SIZE, d.size).add(Document.COLUMN_LAST_MODIFIED, 1_700_000_000_000L)
    }

    override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
        val d = docs.firstOrNull { it.id == documentId } ?: throw java.io.FileNotFoundException()
        if (mode != "r") throw java.io.FileNotFoundException()
        val n = opens.getOrPut(d.id) { AtomicInteger() }.incrementAndGet()
        Log.i(TAG, "OPEN ${d.id} $n")
        val pipe = ParcelFileDescriptor.createPipe()
        Thread {
            try { ParcelFileDescriptor.AutoCloseOutputStream(pipe[1]).use { d.write(it) } } catch (_: IOException) {}
        }.start()
        return pipe[0]
    }

    companion object {
        const val TAG = "PICKFX"
        const val ROOT = "root"
        const val ROOT_TITLE = "OTPanda picker fixture"
    }
}
