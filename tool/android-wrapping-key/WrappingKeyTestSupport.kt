package org.otpanda.wrappingkey

import java.io.File
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** TEST ONLY. A SOFTWARE AES-GCM stand-in for the Keystore: it exercises real GCM authentication but is NOT evidence of Keystore behavior. Keys derive from the namespace so
 * separate JVM processes share them, like processes sharing one Keystore. */
class FakeKeystore {
    val removed: MutableSet<String> = ConcurrentHashMap.newKeySet()
    val present: MutableSet<String> = ConcurrentHashMap.newKeySet()
    @Volatile var generateCount = 0
    @Volatile var failWrap: WrappingKeyFailure? = null
    @Volatile var failEnsure: WrappingKeyFailure? = null
    @Volatile var failDelete: WrappingKeyFailure? = null
    @Volatile var failUnwrap: WrappingKeyFailure? = null
    fun wrapper(ns: String): KeyWrapper = object : KeyWrapper {
        private fun spec() = SecretKeySpec(MessageDigest.getInstance("SHA-256").digest(("test-keystore:$ns").toByteArray()), "AES")
        override fun ensureKey() { failEnsure?.let { throw it }; if (present.add(ns)) { generateCount++; removed.remove(ns) } }
        override fun wrap(plain: ByteArray, aad: ByteArray): ByteArray {
            failWrap?.let { throw it }
            val iv = ByteArray(12).also { java.security.SecureRandom().nextBytes(it) }
            val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, spec(), GCMParameterSpec(128, iv)); updateAAD(aad) }
            return iv + c.doFinal(plain)
        }
        override fun unwrap(wrapped: ByteArray, aad: ByteArray): ByteArray {
            failUnwrap?.let { throw it }
            if (ns in removed) throw WrappingKeyFailure(WrappingKeyFailure.Kind.MISSING_ALIAS)
            return try {
                val c = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, spec(), GCMParameterSpec(128, wrapped.copyOfRange(0, 12))); updateAAD(aad) }
                c.doFinal(wrapped, 12, wrapped.size - 12)
            } catch (_: javax.crypto.AEADBadTagException) { throw WrappingKeyFailure(WrappingKeyFailure.Kind.CORRUPT) }
        }
        override fun deleteKey() { failDelete?.let { throw it }; present.remove(ns); removed.add(ns) }
    }
}

/** TEST ONLY recording directory sync: proves call order and failure handling, NOT durability. */
class RecordingSync(val failFrom: Int = Int.MAX_VALUE) : WkDirSync {
    val calls = mutableListOf<String>(); val blobPresent = mutableListOf<Boolean>()
    override fun sync(dir: File) {
        calls.add(dir.name); blobPresent.add(dir.listFiles()?.any { it.name.endsWith(".key") } == true)
        if (calls.size >= failFrom) throw java.io.IOException("injected")
    }
}
