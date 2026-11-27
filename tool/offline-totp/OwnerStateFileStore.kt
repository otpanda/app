package org.otpanda.totp

import android.content.Context
import android.util.AtomicFile
import java.io.File

/** Durable owner metadata under noBackupFilesDir (not restored without its Keystore keys). One atomic file per owner key. Contains no seed.
 * Unlistable directory or unreadable file throws, so custody fails closed. NOT rollback-proof against someone who can replace files in the app's
 * private directory: that is outside the app sandbox guarantees and is a documented limit, not mitigated here. */
class OwnerStateFileStore(context: Context) : OwnerStateStore {
    private val dir = File(context.noBackupFilesDir, "otpanda-custody-v2")
    private fun file(key: String): AtomicFile {
        require(key.matches(Regex("[0-9a-f]{64}")))
        return AtomicFile(File(dir, "$key.state"))
    }
    override fun read(key: String): String? = try {
        file(key).openRead().use { s ->
            val bytes = readBounded(s, 1_048_577)
            require(bytes.size <= 1_048_576)
            bytes.toString(Charsets.UTF_8)
        }
    } catch (_: java.io.FileNotFoundException) { null }

    override fun write(key: String, text: String) {
        check(dir.isDirectory || dir.mkdirs()) { "State directory unavailable" }
        val atomic = file(key)
        val stream = atomic.startWrite()
        try { stream.write(text.toByteArray(Charsets.UTF_8)); atomic.finishWrite(stream) } catch (e: Exception) { atomic.failWrite(stream); throw e }
    }

    override fun keys(): Set<String> {
        if (!dir.exists()) return emptySet()
        val files = dir.listFiles() ?: throw java.io.IOException("State directory unreadable")
        return files.map { it.name }.filter { it.endsWith(".state") }.map { it.removeSuffix(".state") }.filter { it.matches(Regex("[0-9a-f]{64}")) }.toSet()
    }
}
