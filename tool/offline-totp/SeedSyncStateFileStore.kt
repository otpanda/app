package org.otpanda.totp

import android.content.Context
import android.util.AtomicFile
import java.io.File

/** Durable seed-sync enrollment state under noBackupFilesDir, in its OWN directory (never the custody state directory). One atomic file per owner key.
 * Contains no key material, only opaque ids and aliases. Unlistable directory or unreadable file throws, so callers fail closed. Not rollback-proof against
 * code running as the app UID (same documented limit as OwnerStateFileStore). */
class SeedSyncStateFileStore(context: Context) : SyncStateStore {
    private val dir = File(context.noBackupFilesDir, "otpanda-seedsync-v1")
    private fun file(key: String): AtomicFile {
        require(key.matches(Regex("[0-9a-f]{64}")))
        return AtomicFile(File(dir, "$key.state"))
    }
    override fun read(key: String): String? = try {
        file(key).openRead().use { s ->
            val bytes = readBounded(s, 65_537)
            require(bytes.size <= 65_536)
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
