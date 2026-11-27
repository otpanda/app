package org.otpanda.totp

import android.os.Build
import android.security.keystore.KeyInfo
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.security.keystore.KeyProtection
import android.security.keystore.UserNotAuthenticatedException
import java.security.KeyStore
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.SecretKeySpec

/**
 * Inactive Android Keystore vault. Imports an authorized seed as a non-exportable HMAC key; no auth requirement, so codes work offline on a locked
 * device unless the owner later chooses otherwise (a product decision, not made here). Never reads key bytes back, never falls back to a software key.
 * Not wired into the app host. Behavior on real devices (hardware level per algorithm, uninstall, backup, OS invalidation) is UNVERIFIED by CI.
 */
class AndroidSeedVault : KeyVault {
    private fun store() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private fun digest(a: TotpCalculator.Algorithm) = when (a) {
        TotpCalculator.Algorithm.SHA1 -> KeyProperties.DIGEST_SHA1
        TotpCalculator.Algorithm.SHA256 -> KeyProperties.DIGEST_SHA256
        TotpCalculator.Algorithm.SHA512 -> KeyProperties.DIGEST_SHA512
    }
    override fun containsAlias(alias: String) = try { store().containsAlias(alias) } catch (e: Exception) { throw VaultException(VaultException.Kind.UNAVAILABLE, "keystore", e) }
    override fun aliases(): Set<String> = try { store().aliases().toList().toSet() } catch (e: Exception) { throw VaultException(VaultException.Kind.UNAVAILABLE, "keystore", e) }

    override fun importSeed(alias: String, seed: ByteArray, algorithm: TotpCalculator.Algorithm): ProtectionReport {
        if (Build.VERSION.SDK_INT < 30) throw VaultException(VaultException.Kind.UNAVAILABLE, "unsupported_os")
        try {
            val spec = SecretKeySpec(seed, algorithm.jcaName)
            val protection = KeyProtection.Builder(KeyProperties.PURPOSE_SIGN)
                .setDigests(digest(algorithm))
                .setUserAuthenticationRequired(false)
                .build()
            store().setEntry(alias, KeyStore.SecretKeyEntry(spec), protection)
            // Report the key that was actually stored, not the request.
            val key = store().getKey(alias, null) as SecretKey
            val info = SecretKeyFactory.getInstance(key.algorithm, "AndroidKeyStore").getKeySpec(key, KeyInfo::class.java) as KeyInfo
            // isInsideSecureHardware exists on API 30-35 (deprecated from 31), so this compiles and runs on the whole supported range.
            // It does not distinguish StrongBox from TEE; the level is recorded as "secure_hardware" or "software".
            @Suppress("DEPRECATION")
            val hardware = info.isInsideSecureHardware
            val level = if (hardware) "secure_hardware" else "software"
            return ProtectionReport(hardware, level)
        } catch (e: VaultException) { throw e } catch (e: Exception) {
            // Best effort: Keystore does not report a reason code, so only a size above 64 bytes (the unproven limit) is flagged as likely unsupported.
            val kind = if (seed.size > 64) VaultException.Kind.UNSUPPORTED_SEED else VaultException.Kind.UNAVAILABLE
            throw VaultException(kind, "import_failed", e)
        }
    }

    override fun probe(): ProtectionReport {
        val alias = "otpanda.totp.probe." + java.util.UUID.randomUUID()
        val throwaway = ByteArray(20).also { java.security.SecureRandom().nextBytes(it) }
        try { return importSeed(alias, throwaway, TotpCalculator.Algorithm.SHA1) }
        finally { throwaway.fill(0); runCatching { store().deleteEntry(alias) } }
    }

    override fun key(alias: String): SecretKey? = try {
        store().getKey(alias, null) as SecretKey?
    } catch (e: KeyPermanentlyInvalidatedException) { throw VaultException(VaultException.Kind.INVALIDATED, "invalidated", e)
    } catch (e: UserNotAuthenticatedException) { throw VaultException(VaultException.Kind.LOCKED, "locked", e)
    } catch (e: java.security.UnrecoverableKeyException) { throw VaultException(VaultException.Kind.INVALIDATED, "unrecoverable", e)
    } catch (e: Exception) { throw VaultException(VaultException.Kind.UNAVAILABLE, "keystore", e) }

    override fun delete(alias: String) {
        try { store().deleteEntry(alias) } catch (e: Exception) { throw VaultException(VaultException.Kind.UNAVAILABLE, "delete_failed", e) }
    }
}
