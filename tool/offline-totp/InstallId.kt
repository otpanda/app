package org.otpanda.totp

import java.io.File
import java.io.IOException
import java.nio.file.Files
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

/** Create-only, atomic, durable install id in [dir], which must be ONE level beneath an existing base directory (callers pass a noBackup directory of their own).
 * Publication does NOT use hard links (the platform refuses them for app data, observed EACCES on API 34). Instead every CREATOR takes an exclusive lock: a JVM monitor keyed by
 * the canonical directory (java FileLock is per process, so threads and store objects in one process need it) plus an OS exclusive FileLock on the persistent file
 * "install-id.lock" (cross-process; the OS drops it when its holder dies, even by SIGKILL). The lock file is never removed. Under the lock a creator re-reads the id; only if it is
 * still definitely absent does it write a temp file, fsync it, and publish with an atomic same-directory rename (which would silently replace an existing file, so absence under
 * the lock is the only guard), then confirm the base directory and [dir] with [dirSync]. First create order: mkdir [dir] if absent, create the lock file, confirm base and [dir]
 * with [dirSync], lock, re-read, write, rename, confirm again. READERS do not lock: the rename is atomic, so a reader sees no file or a complete one, and it confirms the
 * directories itself before returning an id. Any failure before the final confirmation fails closed (UNAVAILABLE) and returns no id; the published file is never deleted or
 * overwritten, even after a failed confirmation (its fate is unknown). An EXISTING id is returned only after [dirSync] has confirmed the base and [dir] once in this store
 * object. Never touched by logout, owner switch, session reset, erase or purge. UNVERIFIED on a device: file locking and rename on app data and the real [DirSync]. Stale
 * temp files are ignored (never an id) and not cleaned. BOUND: a create that dies or fails between the temp file write and the rename leaves at most one `tmp-*.part` of at most 64 bytes (when the directory is unwritable even
 * its own cleanup fails). The next create that takes both locks while no id exists deletes every stale `tmp-*.part` (best effort) before writing its own. Bounded when the platform allows unlinking in this directory: then at most one stale file
 * survives a failure streak plus the current one. If unlink is denied, stale temps (at most 64 bytes each) can accumulate, never read as an id and never a safety issue. Cleanup never touches the id or the lock file, and runs only while holding both locks. */
class InstallIdFile(
    private val dir: File,
    private val dirSync: DirSync,
    private val fileSync: (java.io.FileOutputStream) -> Unit = { it.fd.sync() },
    /** Bounded wait for BOTH locks (the in-process one and the OS one). On expiry the call fails closed with UNAVAILABLE and nothing is changed; callers may retry. */
    private val lockWaitMs: Long = 1_000,
) : InstallIdStore {
    private companion object { val monitors = java.util.concurrent.ConcurrentHashMap<String, java.util.concurrent.locks.ReentrantLock>() }
    private val lock = Any()
    private var confirmed = false
    private val target get() = File(dir, "install-id")
    private val lockFile get() = File(dir, "install-id.lock")
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
            // the lock path must be absent or a regular file (lstat): a symlink or directory there is never opened
            val lockAttrs = try { Files.readAttributes(lockFile.toPath(), BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS) } catch (_: NoSuchFileException) { null }
            if (lockAttrs != null && !lockAttrs.isRegularFile) unavailable()
            val raf = java.io.RandomAccessFile(lockFile, "rw") // creates the lock file when absent; never deleted
            try {
                try { dirSync.sync(base); dirSync.sync(dir) } catch (_: Exception) { unavailable() } // the directory entries (dir, lock file) are durable before anything is published
                val mon = monitors.computeIfAbsent(dir.canonicalPath) { java.util.concurrent.locks.ReentrantLock() }
                val deadline = System.nanoTime() + lockWaitMs * 1_000_000
                if (!(try { mon.tryLock(lockWaitMs, java.util.concurrent.TimeUnit.MILLISECONDS) } catch (_: InterruptedException) { Thread.currentThread().interrupt(); false })) unavailable()
                try {
                    var fl: java.nio.channels.FileLock? = null
                    while (fl == null) {
                        fl = try { raf.channel.tryLock() } catch (_: java.nio.channels.OverlappingFileLockException) { null } catch (_: IOException) { unavailable() }
                        if (fl == null) { if (System.nanoTime() >= deadline) unavailable(); try { Thread.sleep(20) } catch (_: InterruptedException) { Thread.currentThread().interrupt(); unavailable() } }
                    }
                    try {
                        readLocked()?.let { return confirmExisting(it) to false } // the winner of a race, or an id whose publication another process finished
                        // Both locks are held and no id exists, so no other creator can be live: temp files from killed or failed creates are stale. Best effort, regular files only, never the id or the lock file.
                        dir.listFiles()?.forEach { f -> if (f.name.startsWith("tmp-") && f.name.endsWith(".part") && Files.isRegularFile(f.toPath(), LinkOption.NOFOLLOW_LINKS)) f.delete() }
                        val temp = File.createTempFile("tmp-", ".part", dir)
                        try {
                            java.io.FileOutputStream(temp).use { s -> s.write(candidate.toByteArray(Charsets.US_ASCII)); fileSync(s) }
                            readLocked()?.let { return confirmExisting(it) to false } // absence re-checked (lstat) immediately before the rename, under the lock
                            try { Files.move(temp.toPath(), target.toPath(), java.nio.file.StandardCopyOption.ATOMIC_MOVE) } catch (_: IOException) { unavailable() }
                        } finally { temp.delete() }
                        confirmDir(); confirmed = true // a failed confirmation throws here: the caller gets no id for a rename that may not survive
                        candidate to true
                    } finally { try { fl.release() } catch (_: IOException) { } }
                } finally { mon.unlock() }
            } finally { try { raf.close() } catch (_: IOException) { } }
        } catch (e: InstallIdFailure) { throw e } catch (_: IOException) { unavailable() } catch (_: SecurityException) { unavailable() }
    }
}
