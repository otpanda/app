package org.otpanda.wrappingkey

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.attribute.BasicFileAttributes

/**
 * Why a wrapping-key operation failed. Wire codes are in [WrappingKeyChannelHandler].
 * LOCKED: user storage or the keystore is not usable yet (credential-encrypted storage before first unlock). Retry after unlock.
 * MISSING_ALIAS: a key blob exists but the Keystore key that wraps it is gone or permanently unusable. NEVER recreate, replace or purge because of it.
 * CORRUPT: a blob exists but is not the exact format, is not a regular file, or fails authentication. Never repaired, replaced or deleted by a read or create.
 * UNAVAILABLE: anything else, including invalid input and a failed write or durability confirmation.
 * [outcomeUnknown] is true only for a mutation that may or may not have been applied; the caller must read back.
 */
class WrappingKeyFailure(val kind: Kind, val outcomeUnknown: Boolean = false) : Exception(kind.name) {
    enum class Kind { UNAVAILABLE, LOCKED, MISSING_ALIAS, CORRUPT }
}

/** The Keystore side, one key per namespace. Implementations throw [WrappingKeyFailure] with the kinds above and never log. */
interface KeyWrapper {
    /** Creates the AES-256-GCM key when no key exists under the alias; never replaces an existing one. */
    fun ensureKey()
    /** Returns iv(12) || ciphertext || tag(16). [aad] is authenticated. */
    fun wrap(plain: ByteArray, aad: ByteArray): ByteArray
    /** MISSING_ALIAS when the key is gone or permanently invalid, CORRUPT on authentication failure. */
    fun unwrap(wrapped: ByteArray, aad: ByteArray): ByteArray
    /** Removes the key. Absent is success. Only the explicit purge calls this. */
    fun deleteKey()
}

/** Forces a directory's entries to stable storage. Must throw on failure. No pure-Java implementation exists, so tests inject a recording fake and say so. */
fun interface WkDirSync { fun sync(dir: File) }

object WrappingKeyFormat {
    const val KEY_BYTES = 32
    const val VERSION: Byte = 1
    const val IV_BYTES = 12
    const val TAG_BYTES = 16
    const val BLOB_BYTES = 1 + IV_BYTES + KEY_BYTES + TAG_BYTES
    private val NAME = Regex("[A-Za-z0-9_-]{1,64}")
    fun validName(s: String) = NAME.matches(s)
    fun aad(namespace: String): ByteArray = ("otpanda.wrapping-key.v1\u0000" + namespace).toByteArray(Charsets.UTF_8)
    fun encode(wrapped: ByteArray): ByteArray = byteArrayOf(VERSION) + wrapped
    /** null unless exactly the v1 layout. */
    fun decode(blob: ByteArray): ByteArray? = if (blob.size == BLOB_BYTES && blob[0] == VERSION) blob.copyOfRange(1, blob.size) else null
}

/**
 * Create-only wrapping key store for Android. The 32-byte random key is exported (the encrypted database needs the raw key) but only ever stored wrapped:
 * AES-GCM under a non-exportable Keystore key, the blob in an app-private noBackup directory. The Keystore key needs no user authentication, so the key is usable on a
 * locked device once the user has unlocked it since boot (the credential-encrypted directory also needs that).
 *
 * Layout in [dir] (ONE level beneath an existing base directory, callers pass a noBackup path): `<ns>.key` (the blob) and `<ns>.lock` (persistent, never removed).
 * Publication follows InstallIdFile: no hard links (the platform refused them for app data, EACCES on API 34). Every CREATOR and DELETER takes a JVM monitor keyed by the
 * canonical lock path plus an OS exclusive FileLock on `<ns>.lock` (cross-process, dropped by the OS on death). Under both locks a creator re-reads, and only when the blob is
 * definitely absent writes a temp file, fsyncs, re-checks absence, publishes with an atomic same-directory rename, confirms the directories, and reads the blob back and unwraps
 * it. READERS do not lock. A blob is never overwritten, and a failed create never deletes a published blob.
 *
 * Absence is never inferred from an error: only a definite NoSuchFile is "absent". An alias without a blob (a crash between key generation and publish) is absence; the next
 * create reuses that alias. A blob without its alias is MISSING_ALIAS, not absence. Every outcome here is JVM-fake tested only: real Keystore, locked-device behavior,
 * rename and fsync on app data, backup exclusion and uninstall are UNVERIFIED until installed qualification.
 */
class WrappingKeyCore(
    private val dir: File,
    private val dirSync: WkDirSync,
    private val wrapperFor: (String) -> KeyWrapper,
    /** True when credential-encrypted storage is available. When false every operation fails LOCKED before touching anything. */
    private val userUnlocked: () -> Boolean = { true },
    private val fileSync: (java.io.FileOutputStream) -> Unit = { it.fd.sync() },
    private val lockWaitMs: Long = 1_000,
) {
    private companion object { val monitors = java.util.concurrent.ConcurrentHashMap<String, java.util.concurrent.locks.ReentrantLock>() }
    private val guard = Any()
    private var confirmed = false

    private fun fail(k: WrappingKeyFailure.Kind, unknown: Boolean = false): Nothing = throw WrappingKeyFailure(k, unknown)
    private fun target(ns: String) = File(dir, "$ns.key")
    private fun lockFile(ns: String) = File(dir, "$ns.lock")
    private fun requireUnlocked() { if (!userUnlocked()) fail(WrappingKeyFailure.Kind.LOCKED) }
    /** An IO failure while storage went locked is LOCKED, not a generic failure. */
    private fun ioFailure(unknown: Boolean = false): Nothing = if (!userUnlocked()) fail(WrappingKeyFailure.Kind.LOCKED, unknown) else fail(WrappingKeyFailure.Kind.UNAVAILABLE, unknown)

    /** null only for a definite NoSuchFile. */
    private fun readBlob(ns: String): ByteArray? {
        val path = target(ns).toPath()
        val attrs = try { Files.readAttributes(path, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS) }
            catch (_: NoSuchFileException) { return null }
            catch (_: IOException) { ioFailure() } catch (_: SecurityException) { ioFailure() }
        if (!attrs.isRegularFile || attrs.size() != WrappingKeyFormat.BLOB_BYTES.toLong()) fail(WrappingKeyFailure.Kind.CORRUPT)
        val bytes = try { Files.newInputStream(path, LinkOption.NOFOLLOW_LINKS).use { s -> readUpTo(s, WrappingKeyFormat.BLOB_BYTES + 1) } } catch (_: IOException) { ioFailure() }
        if (bytes.size != WrappingKeyFormat.BLOB_BYTES) fail(WrappingKeyFailure.Kind.CORRUPT)
        return bytes
    }

    private fun readUpTo(s: java.io.InputStream, limit: Int): ByteArray { // bounded, no API 33 readNBytes
        val out = java.io.ByteArrayOutputStream(); val buf = ByteArray(128)
        while (out.size() < limit) { val n = s.read(buf, 0, minOf(buf.size, limit - out.size())); if (n < 0) break; out.write(buf, 0, n) }
        return out.toByteArray()
    }

    private fun unwrapBlob(ns: String, blob: ByteArray): ByteArray {
        val wrapped = WrappingKeyFormat.decode(blob) ?: fail(WrappingKeyFailure.Kind.CORRUPT)
        val key = wrapperFor(ns).unwrap(wrapped, WrappingKeyFormat.aad(ns))
        if (key.size != WrappingKeyFormat.KEY_BYTES) { key.fill(0); fail(WrappingKeyFailure.Kind.CORRUPT) }
        return key
    }

    private fun confirmDir() { try { dir.parentFile?.let { dirSync.sync(it) }; dirSync.sync(dir) } catch (_: Exception) { ioFailure() } }
    private fun confirmExisting() { if (!confirmed) { confirmDir(); confirmed = true } }

    /** The stored key, or null only when no blob exists. A blob that cannot be read as the stored key THROWS; nothing is changed. */
    fun read(ns: String): ByteArray? = synchronized(guard) {
        if (!WrappingKeyFormat.validName(ns)) fail(WrappingKeyFailure.Kind.UNAVAILABLE)
        requireUnlocked()
        val blob = readBlob(ns) ?: return null
        val key = unwrapBlob(ns, blob)
        try { confirmExisting() } catch (e: Exception) { key.fill(0); throw e }
        key
    }

    /** Create-only. Returns the key stored afterwards (a concurrent or earlier winner is returned, never replaced) and whether this call created it. */
    fun createIfAbsent(ns: String, candidate: ByteArray): Pair<ByteArray, Boolean> = synchronized(guard) {
        try {
            if (!WrappingKeyFormat.validName(ns) || candidate.size != WrappingKeyFormat.KEY_BYTES) fail(WrappingKeyFailure.Kind.UNAVAILABLE)
            requireUnlocked()
            existing(ns)?.let { return it to false }
            withLocks(ns) {
                existing(ns)?.let { return it to false } // the winner of a race, or a publication another process finished
                publish(ns, candidate)
            }
        } catch (e: WrappingKeyFailure) { throw e } catch (_: IOException) { ioFailure() } catch (_: SecurityException) { ioFailure() }
    }

    private fun existing(ns: String): ByteArray? {
        val blob = readBlob(ns) ?: return null
        val key = unwrapBlob(ns, blob)
        try { confirmExisting() } catch (e: Exception) { key.fill(0); throw e }
        return key
    }

    private inline fun <T> withLocks(ns: String, body: () -> T): T {
        val base = dir.parentFile ?: fail(WrappingKeyFailure.Kind.UNAVAILABLE)
        if (!base.isDirectory) fail(WrappingKeyFailure.Kind.UNAVAILABLE)
        if (!dir.isDirectory && !dir.mkdir() && !dir.isDirectory) fail(WrappingKeyFailure.Kind.UNAVAILABLE)
        val lockAttrs = try { Files.readAttributes(lockFile(ns).toPath(), BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS) } catch (_: NoSuchFileException) { null }
        if (lockAttrs != null && !lockAttrs.isRegularFile) fail(WrappingKeyFailure.Kind.UNAVAILABLE)
        val raf = java.io.RandomAccessFile(lockFile(ns), "rw") // creates the lock file when absent; never deleted
        try {
            try { dirSync.sync(base); dirSync.sync(dir) } catch (_: Exception) { ioFailure() }
            val mon = monitors.computeIfAbsent(lockFile(ns).canonicalPath) { java.util.concurrent.locks.ReentrantLock() }
            val deadline = System.nanoTime() + lockWaitMs * 1_000_000
            val got = try { mon.tryLock(lockWaitMs, java.util.concurrent.TimeUnit.MILLISECONDS) } catch (_: InterruptedException) { Thread.currentThread().interrupt(); false }
            if (!got) fail(WrappingKeyFailure.Kind.UNAVAILABLE)
            try {
                var fl: java.nio.channels.FileLock? = null
                while (fl == null) {
                    fl = try { raf.channel.tryLock() } catch (_: java.nio.channels.OverlappingFileLockException) { null } catch (_: IOException) { fail(WrappingKeyFailure.Kind.UNAVAILABLE) }
                    if (fl == null) {
                        if (System.nanoTime() >= deadline) fail(WrappingKeyFailure.Kind.UNAVAILABLE)
                        try { Thread.sleep(20) } catch (_: InterruptedException) { Thread.currentThread().interrupt(); fail(WrappingKeyFailure.Kind.UNAVAILABLE) }
                    }
                }
                try { return body() } finally { try { fl.release() } catch (_: IOException) { } }
            } finally { mon.unlock() }
        } finally { try { raf.close() } catch (_: IOException) { } }
    }

    /** Both locks held and the blob is definitely absent. Failures before the rename are known not applied; from the rename on the outcome is unknown. */
    private fun publish(ns: String, candidate: ByteArray): Pair<ByteArray, Boolean> {
        // Stale temp files from killed or failed creates (no other creator is live under the lock). Best effort, regular files only.
        dir.listFiles()?.forEach { f -> if (f.name.startsWith("$ns.tmp-") && f.name.endsWith(".part") && Files.isRegularFile(f.toPath(), LinkOption.NOFOLLOW_LINKS)) f.delete() }
        val wrapper = wrapperFor(ns)
        wrapper.ensureKey() // an orphan alias from a crashed create is reused; a published blob's alias is never touched here
        val blob = WrappingKeyFormat.encode(wrapper.wrap(candidate, WrappingKeyFormat.aad(ns)))
        if (blob.size != WrappingKeyFormat.BLOB_BYTES) fail(WrappingKeyFailure.Kind.UNAVAILABLE)
        // Prove the freshly wrapped blob opens before it can be published.
        val check = wrapper.unwrap(blob.copyOfRange(1, blob.size), WrappingKeyFormat.aad(ns))
        val ok = check.contentEquals(candidate); check.fill(0)
        if (!ok) fail(WrappingKeyFailure.Kind.UNAVAILABLE)
        val temp = File.createTempFile("$ns.tmp-", ".part", dir)
        var published = false
        try {
            java.io.FileOutputStream(temp).use { s -> s.write(blob); fileSync(s) }
            readBlob(ns)?.let { fail(WrappingKeyFailure.Kind.UNAVAILABLE) } // absence re-checked (lstat) immediately before the rename; an appearance here is not ours to judge
            published = true
            try { Files.move(temp.toPath(), target(ns).toPath(), java.nio.file.StandardCopyOption.ATOMIC_MOVE) } catch (_: IOException) { fail(WrappingKeyFailure.Kind.UNAVAILABLE, true) }
        } catch (e: WrappingKeyFailure) { throw if (published) WrappingKeyFailure(e.kind, true) else e
        } catch (_: IOException) { ioFailure(published)
        } finally { temp.delete() }
        // The rename may have happened: every failure from here is outcome-unknown. The published blob is never deleted.
        try {
            confirmDir(); confirmed = true
            val back = readBlob(ns) ?: fail(WrappingKeyFailure.Kind.UNAVAILABLE)
            val key = unwrapBlob(ns, back)
            if (!key.contentEquals(candidate)) { key.fill(0); fail(WrappingKeyFailure.Kind.CORRUPT) }
            return key to true
        } catch (e: WrappingKeyFailure) { throw WrappingKeyFailure(e.kind, true) }
    }

    /** Explicit purge only. Removes the blob (even a corrupt one), then the Keystore key. Absent is success. Never called by read, create or any recovery path. */
    fun delete(ns: String): Unit = synchronized(guard) {
        try {
            if (!WrappingKeyFormat.validName(ns)) fail(WrappingKeyFailure.Kind.UNAVAILABLE)
            requireUnlocked()
            withLocks(ns) {
                val path = target(ns).toPath()
                val attrs = try { Files.readAttributes(path, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS) } catch (_: NoSuchFileException) { null }
                if (attrs != null && !attrs.isRegularFile) fail(WrappingKeyFailure.Kind.CORRUPT) // nothing deleted yet: known not applied
                // Past this point a failure may follow a partial delete.
                try {
                    if (attrs != null) { Files.delete(path); confirmDir() }
                    wrapperFor(ns).deleteKey()
                } catch (e: WrappingKeyFailure) { throw WrappingKeyFailure(e.kind, true)
                } catch (_: IOException) { ioFailure(true) }
            }
        } catch (e: WrappingKeyFailure) { throw e } catch (_: IOException) { ioFailure() } catch (_: SecurityException) { ioFailure() }
    }
}
