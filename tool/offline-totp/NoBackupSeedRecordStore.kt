package org.otpanda.totp

import android.content.Context
import android.util.AtomicFile
import java.io.File

/** Inactive. Metadata only (never a seed), under noBackupFilesDir so it is not restored without its Keystore key. One atomic file per account. */
class NoBackupSeedRecordStore(context: Context) : RecordStore {
    private val dir = File(context.noBackupFilesDir, "otpanda-totp-v1")
    private fun file(accountId: String): AtomicFile {
        require(accountId.matches(SeedRecord.ID))
        return AtomicFile(File(dir, "$accountId.rec"))
    }
    override fun read(accountId: String): SeedRecord? = try {
        file(accountId).openRead().use { stream ->
            val bytes = readBounded(stream, 401)
            require(bytes.size <= 400)
            SeedRecord.decode(bytes.toString(Charsets.UTF_8)).also { require(it.accountId == accountId) }
        }
    } catch (_: java.io.FileNotFoundException) { null }
    // Malformed or unreadable is an error to the caller, not an empty record to replace.

    override fun accountIds(): Set<String> {
        if (!dir.exists()) return emptySet()
        // An existing directory that cannot be listed is an error, never an empty set: reconcile would treat every key as an orphan.
        val files = dir.listFiles() ?: throw java.io.IOException("Record directory unreadable")
        return files.map { it.name }.filter { it.endsWith(".rec") }.map { it.removeSuffix(".rec") }.filter { it.matches(SeedRecord.ID) }.toSet()
    }

    override fun write(record: SeedRecord) {
        check(dir.isDirectory || dir.mkdirs()) { "Record directory unavailable" }
        check(read(record.accountId) == null) { "Existing record must not be silently replaced" }
        val atomic = file(record.accountId)
        val stream = atomic.startWrite()
        try { stream.write(record.encode().toByteArray(Charsets.UTF_8)); atomic.finishWrite(stream) }
        catch (error: Exception) { atomic.failWrite(stream); throw error }
    }
    override fun delete(accountId: String) { file(accountId).delete() }
}
