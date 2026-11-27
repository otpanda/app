package org.otpanda.wrappingkey

import android.content.Context
import android.os.UserManager
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.security.keystore.UserNotAuthenticatedException
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.IOException
import java.security.KeyStore
import java.security.UnrecoverableKeyException
import javax.crypto.AEADBadTagException
import javax.crypto.BadPaddingException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * AES-256-GCM wrapping under a non-exportable AndroidKeyStore key, one alias per namespace. No user authentication, no StrongBox requirement, no hardware claim:
 * a software-backed Keystore key is accepted (OS-encrypted), as for the other custody keys. The alias never carries key bytes. Never logs.
 * Error mapping is a best reading of the platform contract and is UNVERIFIED on a device: BadPaddingException (including AEADBadTagException) is CORRUPT (wrong tag can be a
 * tampered blob or a different key under the same alias; both mean the stored value is unreadable), an absent alias, KeyPermanentlyInvalidatedException or
 * UnrecoverableKeyException is MISSING_ALIAS, UserNotAuthenticatedException is LOCKED, everything else UNAVAILABLE.
 */
class KeystoreAesGcmWrapper(private val namespace: String) : KeyWrapper {
    private val alias = "otpanda.wrapkey.v1.$namespace"
    private fun store() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    private fun unavailable(): Nothing = throw WrappingKeyFailure(WrappingKeyFailure.Kind.UNAVAILABLE)

    override fun ensureKey() {
        try {
            if (store().containsAlias(alias)) return
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                init(
                    KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .setKeySize(256)
                        .setRandomizedEncryptionRequired(true)
                        .setUserAuthenticationRequired(false)
                        .build()
                )
            }.generateKey()
        } catch (e: WrappingKeyFailure) { throw e } catch (_: Exception) {
            // NEVER delete here: after a failed containsAlias or generateKey the alias may be a pre-existing key (or an orphan a later create reuses). Uncertain stays uncertain;
            // only the explicit purge (deleteKey) removes an alias.
            unavailable()
        }
    }

    private fun key(): SecretKey? = try { store().getKey(alias, null) as? SecretKey } catch (_: UnrecoverableKeyException) {
        throw WrappingKeyFailure(WrappingKeyFailure.Kind.MISSING_ALIAS)
    }

    override fun wrap(plain: ByteArray, aad: ByteArray): ByteArray = try {
        val k = key() ?: unavailable() // ensureKey ran just before; a vanished key here is not a verdict about stored data
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, k); updateAAD(aad) }
        val iv = c.iv
        if (iv == null || iv.size != WrappingKeyFormat.IV_BYTES) unavailable()
        iv + c.doFinal(plain)
    } catch (e: WrappingKeyFailure) { throw e
    } catch (_: KeyPermanentlyInvalidatedException) { throw WrappingKeyFailure(WrappingKeyFailure.Kind.MISSING_ALIAS)
    } catch (_: UserNotAuthenticatedException) { throw WrappingKeyFailure(WrappingKeyFailure.Kind.LOCKED)
    } catch (_: Exception) { unavailable() }

    override fun unwrap(wrapped: ByteArray, aad: ByteArray): ByteArray = try {
        if (wrapped.size != WrappingKeyFormat.BLOB_BYTES - 1) throw WrappingKeyFailure(WrappingKeyFailure.Kind.CORRUPT)
        val k = key() ?: throw WrappingKeyFailure(WrappingKeyFailure.Kind.MISSING_ALIAS)
        val iv = wrapped.copyOfRange(0, WrappingKeyFormat.IV_BYTES)
        val c = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.DECRYPT_MODE, k, GCMParameterSpec(WrappingKeyFormat.TAG_BYTES * 8, iv)); updateAAD(aad)
        }
        c.doFinal(wrapped, WrappingKeyFormat.IV_BYTES, wrapped.size - WrappingKeyFormat.IV_BYTES)
    } catch (e: WrappingKeyFailure) { throw e
    } catch (_: AEADBadTagException) { throw WrappingKeyFailure(WrappingKeyFailure.Kind.CORRUPT)
    } catch (_: BadPaddingException) { throw WrappingKeyFailure(WrappingKeyFailure.Kind.CORRUPT)
    } catch (_: KeyPermanentlyInvalidatedException) { throw WrappingKeyFailure(WrappingKeyFailure.Kind.MISSING_ALIAS)
    } catch (_: UserNotAuthenticatedException) { throw WrappingKeyFailure(WrappingKeyFailure.Kind.LOCKED)
    } catch (_: Exception) { unavailable() }

    override fun deleteKey() { try { store().deleteEntry(alias) } catch (_: Exception) { unavailable() } }
}

/** Opens the directory, fsyncs it and closes it with platform calls. Any errno becomes an IOException so the caller fails closed. UNVERIFIED on a device. */
class AndroidWkDirSync : WkDirSync {
    override fun sync(dir: File) {
        val fd = try { Os.open(dir.path, OsConstants.O_RDONLY, 0) } catch (e: ErrnoException) { throw IOException("open failed") }
        try { Os.fsync(fd) } catch (e: ErrnoException) { throw IOException("fsync failed") }
        finally { try { Os.close(fd) } catch (_: ErrnoException) { } }
    }
}

/** The production wiring: blobs under noBackupFilesDir (excluded from backup and device transfer), real Keystore wrapper, real directory sync, UserManager unlock state. */
fun androidWrappingKeyCore(context: Context): WrappingKeyCore {
    val app = context.applicationContext
    val um = app.getSystemService(UserManager::class.java)
    return WrappingKeyCore(
        dir = File(app.noBackupFilesDir, "otpanda-wrapping-key-v1"),
        dirSync = AndroidWkDirSync(),
        wrapperFor = { KeystoreAesGcmWrapper(it) },
        userUnlocked = { um?.isUserUnlocked ?: false },
    )
}
