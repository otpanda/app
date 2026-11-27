package org.otpanda.totp

import android.content.Context
import android.util.AtomicFile
import java.io.File
import java.io.IOException
import java.security.SecureRandom

/** The admission document: one atomic file under noBackupFilesDir (excluded from backup and device transfer, never restored without the Keystore keys it relates to).
 * AtomicFile fsyncs the file; the directories are then confirmed with the platform dir sync, and a failed confirmation throws (the next read decides what was applied).
 * Contains no secret: owner id, install id, epoch, scope states and the canary id. UNVERIFIED on a device. */
class AndroidWorkspaceAdmissionDocs(context: Context, private val dirSync: DirSync = AndroidDirSync()) : AdmissionDocs {
    private val dir = File(context.noBackupFilesDir, "otpanda-workspace-admission-v1")
    private val file get() = AtomicFile(File(dir, "admission"))
    /** Absent only when the file system definitely says so (admissionDocPresence). Any open failure, including FileNotFoundException on an existing unreadable file or directory, is thrown, never null. */
    override fun read(): String? {
        if (admissionDocPresence(dir) == DocPresence.ABSENT) return null
        return file.openRead().use { s -> val b = readBounded(s, 65_537); require(b.size <= 65_536); String(b, Charsets.UTF_8) }
    }
    override fun write(text: String) {
        check(dir.isDirectory || dir.mkdir() || dir.isDirectory) { "admission directory unavailable" }
        val atomic = file
        val out = atomic.startWrite()
        try { out.write(text.toByteArray(Charsets.UTF_8)); atomic.finishWrite(out) } catch (e: Exception) { atomic.failWrite(out); throw e }
        dir.parentFile?.let { dirSync.sync(it) }; dirSync.sync(dir)
    }
}

/** The create-only canary, in its own directory, with the existing install-id machinery (locks, temp file, atomic rename, directory sync). */
class NoBackupWorkspaceCanary(context: Context) : InstallIdStore by InstallIdFile(File(context.noBackupFilesDir, "otpanda-workspace-canary-v1"), AndroidDirSync())

/** Private database path: noBackup, one directory, file name from the scope key only. Dart never supplies any part of it. */
fun androidWorkspacePathFor(context: Context): (String) -> String {
    val dir = File(context.noBackupFilesDir, "otpanda-workspace-v1")
    return { key -> require(Regex("[0-9a-f]{64}").matches(key)); File(dir, "$key.db").path }
}

/** mkdir of the private database directory, then base and directory confirmed durable. An existing non-directory fails closed. */
fun androidPrepareWorkspaceDir(context: Context, dirSync: DirSync = AndroidDirSync()): () -> Unit = {
    val dir = File(context.noBackupFilesDir, "otpanda-workspace-v1")
    if (!dir.isDirectory && !dir.mkdir() && !dir.isDirectory) throw IOException("workspace directory unavailable")
    dir.parentFile?.let { dirSync.sync(it) }; dirSync.sync(dir)
}

fun newCanaryId(): String {
    val b = ByteArray(32).also { SecureRandom().nextBytes(it) }
    return java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(b) // 43 chars, passes validInstallId
}
