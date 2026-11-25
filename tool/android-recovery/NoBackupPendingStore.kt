package org.otpanda.recovery

import android.content.Context
import android.util.AtomicFile
import java.io.File

/**
 * Progress of one enrollment (key created, begin sent, finish sent). Dart owns
 * the format; this stores an opaque UTF-8 string of at most 2048 bytes in
 * no-backup storage. It is cleared only after a typed server confirmation and
 * never on an unknown outcome.
 */
class NoBackupPendingStore(context: Context, slot: String = "enroll") {
    companion object { private val lock = Any(); const val MAX = 2048 }
    private val file = AtomicFile(File(context.noBackupFilesDir, if (slot == "add") "otpanda-add-pending-v1" else "otpanda-enroll-pending-v1"))
    fun read(): String? = synchronized(lock) {
        try {
            file.openRead().use { s ->
                val bytes = s.readBytes()
                if (bytes.size > MAX) throw java.io.IOException("pending record oversize") else bytes.toString(Charsets.UTF_8)
            }
        } catch (_: java.io.FileNotFoundException) { null }
    }
    fun write(record: String) = synchronized(lock) {
        val bytes = record.toByteArray(Charsets.UTF_8)
        require(bytes.size <= MAX) { "record too large" }
        val out = file.startWrite()
        try { out.write(bytes); file.finishWrite(out) } catch (e: Exception) { file.failWrite(out); throw e }
    }
    fun clear() = synchronized(lock) { file.delete() }
}
