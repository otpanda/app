package org.otpanda.recovery

import android.content.Context
import android.util.AtomicFile
import java.io.File

/** Only write after a separately verified server enrollment confirmation. */
class NoBackupEnrollmentStore(context: Context) {
    companion object { private val lock = Any() }
    private val file = AtomicFile(File(context.noBackupFilesDir,"otpanda-enrollment-v1"))
    fun read(): EnrollmentRecord? = synchronized(lock) {
        try {
            file.openRead().use { stream ->
                val bytes = ByteArray(401)
                var size = 0
                while(size < bytes.size) {
                    val n = stream.read(bytes,size,bytes.size-size)
                    if(n < 0) break
                    size += n
                }
                require(size <= 400)
                EnrollmentRecord.decode(bytes.copyOf(size).toString(Charsets.UTF_8))
            }
        } catch (_: java.io.FileNotFoundException) { null }
        // Other failures are unavailable, not an empty enrollment to replace.
    }
    fun saveConfirmed(record: EnrollmentRecord) = synchronized(lock) {
        val current = read()
        if (current == record) return@synchronized
        check(current == null) { "Existing enrollment must not be silently replaced" }
        val bytes=record.encode().toByteArray(Charsets.UTF_8)
        val stream=file.startWrite()
        try { stream.write(bytes); file.finishWrite(stream) }
        catch(error: Exception) { file.failWrite(stream); throw error }
    }
}
