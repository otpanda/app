package org.otpanda.totp

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.security.keystore.UserNotAuthenticatedException
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec

/**
 * Inactive Android Keystore signing vault for the seed-sync enrollment key: one non-exportable EC P-256 key per alias, PURPOSE_SIGN with SHA-256 only, no user
 * authentication requirement (offline use on a locked device is the product decision recorded for offline keys; changing it is not made here). It never reads
 * private key bytes, never falls back to a software key, and never reuses an alias: generate refuses an existing alias (SyncKeyCore always picks a fresh one).
 * [sign] returns the platform's ASN.1 DER ECDSA signature; SeedSyncWire.derToP1363 converts it strictly. Not wired into the app host.
 * UNVERIFIED by CI: hardware level (StrongBox or TEE), behavior on lock, uninstall, backup, factory reset and OS invalidation. Whether the key is hardware backed is
 * not requested or reported here.
 */
class AndroidSyncKeyVault : SyncKeyVault {
    private fun store() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private fun unavailable(e: Exception, why: String) = VaultException(VaultException.Kind.UNAVAILABLE, why, e)

    override fun containsAlias(alias: String) = try { store().containsAlias(alias) } catch (e: Exception) { throw unavailable(e, "keystore") }
    override fun aliases(): Set<String> = try { store().aliases().toList().toSet() } catch (e: Exception) { throw unavailable(e, "keystore") }

    override fun generate(alias: String): ByteArray {
        try {
            if (store().containsAlias(alias)) throw VaultException(VaultException.Kind.UNAVAILABLE, "alias_exists")
            val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setUserAuthenticationRequired(false)
                .build()
            val pair = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").apply { initialize(spec) }.generateKeyPair()
            val w = (pair.public as ECPublicKey).w
            fun fixed(b: java.math.BigInteger): ByteArray {
                val raw = b.toByteArray()
                return when {
                    raw.size == 32 -> raw
                    raw.size == 33 && raw[0] == 0.toByte() -> raw.copyOfRange(1, 33)
                    raw.size < 32 -> ByteArray(32 - raw.size) + raw
                    else -> throw VaultException(VaultException.Kind.UNAVAILABLE, "bad_point")
                }
            }
            return byteArrayOf(4) + fixed(w.affineX) + fixed(w.affineY)
        } catch (e: VaultException) { throw e } catch (e: Exception) {
            runCatching { store().deleteEntry(alias) } // do not leave a half-made key under a name the caller will treat as unused
            throw unavailable(e, "generate_failed")
        }
    }

    override fun sign(alias: String, message: ByteArray): ByteArray {
        try {
            val key = store().getKey(alias, null) as? PrivateKey ?: throw VaultException(VaultException.Kind.INVALIDATED, "missing")
            return Signature.getInstance("SHA256withECDSA").run { initSign(key); update(message); sign() }
        } catch (e: VaultException) { throw e
        } catch (e: KeyPermanentlyInvalidatedException) { throw VaultException(VaultException.Kind.INVALIDATED, "invalidated", e)
        } catch (e: UserNotAuthenticatedException) { throw VaultException(VaultException.Kind.LOCKED, "locked", e)
        } catch (e: java.security.UnrecoverableKeyException) { throw VaultException(VaultException.Kind.INVALIDATED, "unrecoverable", e)
        } catch (e: Exception) { throw unavailable(e, "sign_failed") }
    }

    override fun delete(alias: String) {
        try { store().deleteEntry(alias) } catch (e: Exception) { throw unavailable(e, "delete_failed") }
    }
}
