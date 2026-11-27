package org.otpanda.totp

import java.security.InvalidKeyException
import javax.crypto.SecretKey

/** What the platform key store says about an imported key. Reported, never assumed. */
data class ProtectionReport(val insideSecureHardware: Boolean, val level: String)

/** Platform key vault. Real implementation: AndroidSeedVault (Android Keystore). No raw-key read exists on this interface. */
interface KeyVault {
    fun containsAlias(alias: String): Boolean
    fun aliases(): Set<String>
    /** Imports seed bytes as a non-exportable HMAC key and reports the protection of the key actually stored. Throws VaultException on failure. */
    fun importSeed(alias: String, seed: ByteArray, algorithm: TotpCalculator.Algorithm): ProtectionReport
    /** The handle, or null when the alias is absent. Throws VaultException(INVALIDATED/LOCKED/UNAVAILABLE) for platform refusals. */
    fun key(alias: String): SecretKey?
    fun delete(alias: String)
    /** Imports a throwaway random key under a temporary alias, reports what the platform says about it, and deletes it. Never a real seed.
     * Default: unsupported, so older fakes keep compiling. */
    fun probe(): ProtectionReport = throw VaultException(VaultException.Kind.UNAVAILABLE, "probe_unsupported")
}

class VaultException(val kind: Kind, message: String, cause: Throwable? = null) : Exception(message, cause) {
    enum class Kind { INVALIDATED, LOCKED, UNAVAILABLE, UNSUPPORTED_SEED }
}

/** Nonsecret metadata persisted with the key alias. The seed itself is never in a record. Store under Context.noBackupFilesDir. */
data class SeedRecord(
    val accountId: String, val alias: String, val algorithm: TotpCalculator.Algorithm,
    val digits: Int, val periodSeconds: Int, val protection: String, val createdAtSeconds: Long,
) {
    init {
        require(accountId.matches(ID)) { "Opaque account id required" }
        require(alias == aliasFor(accountId)) { "Alias must derive from the account id" }
        require(digits in 6..8 && periodSeconds in 1..3600)
        require(protection.matches(Regex("[a-z0-9_-]{1,32}")))
        require(createdAtSeconds >= 0)
    }
    fun encode(): String =
        "otpanda-seed-record-v1\n$accountId\n${algorithm.name}\n$digits\n$periodSeconds\n$protection\n$createdAtSeconds\n"
    companion object {
        val ID = Regex("[A-Za-z0-9_-]{1,64}")
        fun aliasFor(accountId: String) = "otpanda.totp.v1.$accountId"
        /** Strict: exact version, exact field count, canonical re-encoding. Anything else is unusable, never partially read. */
        fun decode(text: String): SeedRecord {
            require(text.length <= 400)
            val p = text.split('\n')
            require(p.size == 8 && p[0] == "otpanda-seed-record-v1" && p[7].isEmpty())
            val algorithm = TotpCalculator.Algorithm.entries.firstOrNull { it.name == p[2] } ?: error("Unknown algorithm")
            val record = SeedRecord(p[1], aliasFor(p[1]), algorithm, p[3].toInt(), p[4].toInt(), p[5], p[6].toLong())
            require(record.encode() == text)
            return record
        }
    }
}

/** Atomic record store. write replaces nothing: callers check first. */
interface RecordStore {
    fun read(accountId: String): SeedRecord?
    fun accountIds(): Set<String>
    fun write(record: SeedRecord)
    fun delete(accountId: String)
}

sealed class CodeResult {
    data class Code(val value: TotpCalculator.Value) : CodeResult()
    object NotProvisioned : CodeResult()
    /** Metadata exists but the key is gone (reinstall, data clear, key loss). Re-provision from the authorized cloud seed. Never recreated here. */
    object KeyMissing : CodeResult()
    /** The platform refused the key permanently, or metadata and key disagree. */
    data class Invalidated(val reason: String) : CodeResult()
    /** Device locked or authentication needed. Not an error to repair. */
    object Locked : CodeResult()
    data class Unavailable(val reason: String) : CodeResult()
}

class CustodyException(val reason: String) : Exception(reason)

/**
 * Local-only custody of authorized TOTP seeds behind a platform key vault, feeding TotpCalculator with key HANDLES.
 * No network, sync, export or raw-key path. No software or plaintext fallback anywhere: a refused or missing key is reported as such.
 * Offline use is real, but a retained key keeps generating after cloud revocation until the seed is rotated or the device reconnects.
 */
class LocalSeedCustody(
    private val vault: KeyVault, private val records: RecordStore,
    /** TEST SEAM ONLY. Must never be set by app/release code: it permits software-backed keys. Default false. */
    private val allowSoftwareKeysForTests: Boolean = false,
) {
    private val requireSecureHardware get() = !allowSoftwareKeysForTests
    companion object { const val MIN_SEED = 10; const val MAX_SEED = 128 }
    private val lock = Any()

    /** Create-only. A second provision for the same account fails; rotation is an explicit delete then provision by the caller.
     * The CALLER'S seed array is zeroed before return on every path; copies made by SecretKeySpec, the JCA provider or JNI are not guaranteed to be wiped. Metadata is written only AFTER the key is verified, so a crash leaves at worst an
     * orphan key (reconcile removes it) and never metadata without a key from this call. */
    fun provision(accountId: String, seed: ByteArray, algorithm: TotpCalculator.Algorithm, digits: Int, periodSeconds: Int, nowSeconds: Long) =
        synchronized(lock) {
            try {
                require(accountId.matches(SeedRecord.ID)) { "Opaque account id required" }
                require(seed.size in MIN_SEED..MAX_SEED) { "Seed length out of range" }
                require(digits in 6..8 && periodSeconds in 1..3600 && nowSeconds >= 0)
                val alias = SeedRecord.aliasFor(accountId)
                // A real record means already provisioned (create-only). A key with no record is a crash orphan: remove it, then proceed.
                if (records.read(accountId) != null) throw CustodyException("already_provisioned")
                if (vault.containsAlias(alias)) {
                    try { vault.delete(alias) } catch (_: Exception) { throw CustodyException("orphan_cleanup_failed") }
                }
                val report = try { vault.importSeed(alias, seed, algorithm) } catch (error: VaultException) {
                    runCatching { vault.delete(alias) }
                    throw CustodyException("vault_" + error.kind.name.lowercase())
                }
                if (requireSecureHardware && !report.insideSecureHardware) {
                    vault.delete(alias)
                    throw CustodyException("protection_too_weak")
                }
                try {
                    records.write(SeedRecord(accountId, alias, algorithm, digits, periodSeconds, report.level, nowSeconds))
                } catch (error: Exception) {
                    runCatching { vault.delete(alias) }
                    throw CustodyException("record_write_failed")
                }
            } finally { seed.fill(0) }
        }

    fun generate(accountId: String, unixSeconds: Long): CodeResult = synchronized(lock) {
        if (!accountId.matches(SeedRecord.ID)) return CodeResult.NotProvisioned
        val record = try { records.read(accountId) } catch (_: Exception) { return CodeResult.Unavailable("record_unreadable") }
        val key = try { vault.key(SeedRecord.aliasFor(accountId)) } catch (error: VaultException) {
            return when (error.kind) {
                VaultException.Kind.INVALIDATED -> CodeResult.Invalidated("key_invalidated")
                VaultException.Kind.LOCKED -> CodeResult.Locked
                VaultException.Kind.UNAVAILABLE, VaultException.Kind.UNSUPPORTED_SEED -> CodeResult.Unavailable("vault_unavailable")
            }
        }
        if (record == null) return if (key == null) CodeResult.NotProvisioned else CodeResult.Invalidated("orphan_key_without_metadata")
        if (key == null) return CodeResult.KeyMissing
        // The digest comes only from the persisted record; key.algorithm must agree, but a matching name is not proof of device digest binding.
        if (key.algorithm != record.algorithm.jcaName) return CodeResult.Invalidated("algorithm_mismatch")
        return try {
            CodeResult.Code(TotpCalculator.generate(key, unixSeconds, record.algorithm, record.digits, record.periodSeconds))
        } catch (error: InvalidKeyException) {
            classify(error)
        } catch (error: java.security.ProviderException) {
            classify(error)
        } catch (_: IllegalArgumentException) {
            CodeResult.Unavailable("invalid_time")
        }
    }

    private fun classify(error: Throwable): CodeResult = classifyKeyFailure(error)

    /** Explicit removal. Metadata goes first: a crash in between leaves an orphan key that reconcile removes, never metadata pointing at nothing. */
    fun delete(accountId: String) = synchronized(lock) {
        require(accountId.matches(SeedRecord.ID))
        records.delete(accountId)
        vault.delete(SeedRecord.aliasFor(accountId))
    }

    fun accounts(): Map<String, SeedRecord> = synchronized(lock) {
        records.accountIds().mapNotNull { id -> runCatching { records.read(id) }.getOrNull()?.let { id to it } }.toMap()
    }

    /** Removes only keys of this scheme that have no metadata (interrupted provision or delete). Never touches metadata, never recreates a key. */
    fun reconcile(): Set<String> = synchronized(lock) {
        val known = records.accountIds().map { SeedRecord.aliasFor(it) }.toSet()
        val orphans = vault.aliases().filter { it.startsWith("otpanda.totp.v1.") && it !in known }.toSet()
        orphans.forEach { vault.delete(it) }
        orphans
    }
}

/** Maps a platform key failure to a state by exception class NAME along the cause chain, so the JVM core needs no Android classes. */
fun classifyKeyFailure(error: Throwable): CodeResult {
    var cause: Throwable? = error
    while (cause != null) {
        when (cause.javaClass.simpleName) {
            "KeyPermanentlyInvalidatedException" -> return CodeResult.Invalidated("key_invalidated")
            "UserNotAuthenticatedException", "DeviceLockedException" -> return CodeResult.Locked
        }
        cause = cause.cause
    }
    return CodeResult.Unavailable("key_rejected")
}

/** Bounded read for API 30-32 (InputStream.readNBytes needs API 33). Returns at most [limit] bytes; the caller checks for overflow with limit+1. */
fun readBounded(stream: java.io.InputStream, limit: Int): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    val buffer = ByteArray(128)
    while (out.size() < limit) {
        val n = stream.read(buffer, 0, minOf(buffer.size, limit - out.size()))
        if (n < 0) break
        out.write(buffer, 0, n)
    }
    return out.toByteArray()
}
