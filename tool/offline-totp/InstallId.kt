package org.otpanda.totp

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.FileAlreadyExistsException
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.attribute.BasicFileAttributes

/** Why an install id operation failed. UNREADABLE: an existing entry is malformed, not a regular file, or cannot be examined (nothing is changed, native never overwrites it).
 * UNAVAILABLE: a write, publish or durability confirmation failed, so no id may be treated as committed. */
class InstallIdFailure(val kind: Kind) : Exception(kind.name) { enum class Kind { INVALID_INPUT, UNREADABLE, UNAVAILABLE } }

/** The per-install id the server sees in enrollment. Dart generates it (32 random bytes, base64url, no padding); native only persists it, create-only. */
interface InstallIdStore {
    /** null ONLY when no id has ever been stored (the entry does not exist). A malformed, non-regular, unexaminable (for example an unsearchable parent) or unconfirmed-durable
     * entry THROWS [InstallIdFailure]; it is never repaired, deleted or replaced. */
    fun read(): String?
    /** Stores [candidate] only if no id exists and returns (the id now stored and durably confirmed, whether this call created it). A concurrent or earlier winner is returned,
     * never replaced. If durability cannot be confirmed this throws UNAVAILABLE, even when the entry exists. */
    fun createIfAbsent(candidate: String): Pair<String, Boolean>
}

/** Forces a directory's entries to stable storage (open the directory, fsync, close). Must throw if the confirmation fails. There is deliberately NO pure-Java implementation: plain
 * Java cannot fsync a directory, so a store without a real one cannot claim durability. Tests inject a recording fake and say so. */
fun interface DirSync { fun sync(dir: File) }

private val INSTALL_ID = Regex("[A-Za-z0-9_-]{22,64}")
fun validInstallId(s: String) = INSTALL_ID.matches(s)

/** Create-only, atomic, durable install id in [dir], which must be ONE level beneath an existing base directory (callers pass a noBackup directory of their own). Order of a first
 * create: mkdir [dir] if absent, then confirm the base directory and [dir] with [dirSync]; write a temp file and fsync it; publish with a hard link, which fails atomically when
 * the target exists; confirm [dir] with [dirSync] again. Any failure before the final confirmation fails closed (UNAVAILABLE) and returns no id. An EXISTING id is returned only
 * after [dirSync] has confirmed its directory and the base directory once in this store object, so a link whose confirmation failed is never reported as committed on the retry path either. The target
 * is never deleted or overwritten, even after a failed confirmation (its fate is unknown). Never touched by logout, owner switch, session reset, erase or purge.
 * UNVERIFIED on a device: that the platform allows the link call for app data and the real [DirSync] behaves. Stale temp files are ignored (never an id), not cleaned. */
class InstallIdFile(
    private val dir: File,
    private val dirSync: DirSync,
    private val fileSync: (java.io.FileOutputStream) -> Unit = { it.fd.sync() },
) : InstallIdStore {
    private val lock = Any()
    private var confirmed = false
    private val target get() = File(dir, "install-id")
    private fun unreadable(): Nothing = throw InstallIdFailure(InstallIdFailure.Kind.UNREADABLE)
    private fun unavailable(): Nothing = throw InstallIdFailure(InstallIdFailure.Kind.UNAVAILABLE)

    /** null only for a definite NoSuchFile (the file, or the directory that would hold it, does not exist). Any other examination failure is UNREADABLE. */
    private fun readLocked(): String? {
        val path = target.toPath()
        val attrs = try { Files.readAttributes(path, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS) }
            catch (_: NoSuchFileException) { return null }
            catch (_: IOException) { unreadable() } catch (_: SecurityException) { unreadable() }
        if (!attrs.isRegularFile || attrs.size() > 128) unreadable()
        val bytes = try { Files.newInputStream(path, LinkOption.NOFOLLOW_LINKS).use { readBounded(it, 129) } } catch (_: IOException) { unreadable() }
        if (bytes.size > 128) unreadable()
        val text = String(bytes, Charsets.ISO_8859_1)
        if (!validInstallId(text)) unreadable()
        return text
    }

    private fun confirmDir() { try { dir.parentFile?.let { dirSync.sync(it) }; dirSync.sync(dir) } catch (_: Exception) { unavailable() } }
    private fun confirmExisting(id: String): String { if (!confirmed) { confirmDir(); confirmed = true }; return id }

    override fun read(): String? = synchronized(lock) { readLocked()?.let { confirmExisting(it) } }

    override fun createIfAbsent(candidate: String): Pair<String, Boolean> = synchronized(lock) {
        if (!validInstallId(candidate)) throw InstallIdFailure(InstallIdFailure.Kind.INVALID_INPUT)
        readLocked()?.let { return confirmExisting(it) to false }
        try {
            val base = dir.parentFile ?: unavailable()
            if (!base.isDirectory) unavailable()
            if (!dir.isDirectory && !dir.mkdir() && !dir.isDirectory) unavailable()
            try { dirSync.sync(base); dirSync.sync(dir) } catch (_: Exception) { unavailable() } // the directory entry itself is durable before anything is published in it
            val temp = File.createTempFile("tmp-", ".part", dir)
            try {
                java.io.FileOutputStream(temp).use { s -> s.write(candidate.toByteArray(Charsets.US_ASCII)); fileSync(s) }
                val created = try { Files.createLink(target.toPath(), temp.toPath()); true } catch (_: FileAlreadyExistsException) { false }
                val id = if (created) candidate else (readLocked() ?: unreadable())
                confirmDir(); confirmed = true // a failed confirmation throws here: the caller gets no id for a link that may not survive
                id to created
            } finally { temp.delete() }
        } catch (e: InstallIdFailure) { throw e } catch (_: IOException) { unavailable() } catch (_: SecurityException) { unavailable() }
    }
}
