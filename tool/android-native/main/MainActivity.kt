package app.otpanda

import android.content.Intent
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pendingLink: String? = null
    private val prefs get() = getSharedPreferences("otpanda_native", Context.MODE_PRIVATE)
    private val aliases = arrayOf("otpanda_renewal_a", "otpanda_renewal_b")

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        AppLockHost.protect(this)
        super.onCreate(savedInstanceState)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) { LocalLockRecoveryHost.dispose(); super.cleanUpFlutterEngine(flutterEngine) }
    override fun onStop(){LocalLockRecoveryHost.reset();super.onStop()}
    override fun onDestroy(){LocalLockRecoveryHost.reset();AppLockHost.reset();super.onDestroy()}

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app.otpanda/native")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "ensureKey" -> result.success(ensureActive())
                    "beginNewKey" -> result.success(beginNew())
                    "commitNewKey" -> { commitNew(); result.success(null) }
                    "discardNewKey" -> { discardNew(); result.success(null) }
                    "hasPendingKey" -> result.success(activeAlias() != null && store().containsAlias(pendingAlias()))
                    "sign" -> result.success(sign(call.argument<ByteArray>("message")!!, call.argument<Boolean>("pending") == true))
                    "deleteKey" -> { aliases.forEach { deleteKey(it) }; prefs.edit().remove("active").apply(); result.success(null) }
                    "readDeviceId" -> result.success(prefs.getString("device_id", null))
                    "writeDeviceId" -> { LocalLockRecoveryHost.reset(); prefs.edit().putString("device_id", call.argument<String>("id")).commit(); result.success(null) }
                    "clearDeviceId" -> { LocalLockRecoveryHost.reset(); prefs.edit().remove("device_id").commit(); result.success(null) }
                    "readRecognition" -> result.success(readRecognition())
                    "writeRecognition" -> { writeRecognition(call.argument<String>("value")!!); result.success(null) }
                    "clearRecognition" -> { clearRecognition(); result.success(null) }
                    "deviceLabel" -> result.success(deviceLabel())
                    "takeInitialLink" -> { val l = pendingLink; pendingLink = null; result.success(l) }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("keystore", e.javaClass.simpleName, null)
            }
        }
        AppLockHost.register(this, flutterEngine.dartExecutor.binaryMessenger)
        LocalLockRecoveryHost.register(this, flutterEngine.dartExecutor.binaryMessenger)
        GoogleFlavor.register(this, flutterEngine.dartExecutor.binaryMessenger)
        PasskeyHost.register(this, flutterEngine.dartExecutor.binaryMessenger)
        DeviceProofHost.register(this, flutterEngine.dartExecutor.binaryMessenger)
        captureLink(intent)
    }

    // Google recognition secret: AES-GCM under a non-exportable AndroidKeyStore
    // key. Only ciphertext and IV reach a no-backup file. Never logged. Any
    // failure reads as "no recognition" (the server then falls back to browser).
    private val recognitionAlias = "otpanda_recognition"

    private fun recognitionKey(): javax.crypto.SecretKey {
        (store().getKey(recognitionAlias, null) as? javax.crypto.SecretKey)?.let { return it }
        val gen = javax.crypto.KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(
                recognitionAlias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build()
        )
        return gen.generateKey()
    }

    // noBackupFilesDir is excluded from auto-backup and device transfer.
    private val recognitionFile get() = java.io.File(noBackupFilesDir, "recognition.bin")

    private fun writeRecognition(value: String) {
        require(value.isNotEmpty() && value.length <= 200)
        val c = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        c.init(javax.crypto.Cipher.ENCRYPT_MODE, recognitionKey())
        val ct = c.doFinal(value.toByteArray(Charsets.UTF_8))
        val tmp = java.io.File(noBackupFilesDir, "recognition.tmp")
        tmp.writeBytes(byteArrayOf(c.iv.size.toByte()) + c.iv + ct)
        require(tmp.renameTo(recognitionFile))
    }

    private fun readRecognition(): String? = try {
        val f = recognitionFile
        if (!f.exists()) null else {
            val raw = f.readBytes()
            val n = raw[0].toInt()
            val c = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
            c.init(
                javax.crypto.Cipher.DECRYPT_MODE, recognitionKey(),
                javax.crypto.spec.GCMParameterSpec(128, raw.copyOfRange(1, 1 + n))
            )
            String(c.doFinal(raw.copyOfRange(1 + n, raw.size)), Charsets.UTF_8)
        }
    } catch (e: Exception) { null }

    private fun clearRecognition() {
        recognitionFile.delete()
        try { store().deleteEntry(recognitionAlias) } catch (e: Exception) {}
    }

    // Best-effort display label only: the user-set device name when readable,
    // else the model. No permission, no serial/Android ID.
    private fun deviceLabel(): String? {
        val named = try {
            android.provider.Settings.Global.getString(contentResolver, "device_name")
        } catch (e: Exception) { null }
        val v = (named ?: android.os.Build.MODEL)?.trim().orEmpty()
        if (v.isEmpty()) return null
        return if (v.codePointCount(0, v.length) <= 40) v
        else v.substring(0, v.offsetByCodePoints(0, 40))
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        captureLink(intent)
        // The link stays pending until Dart acknowledges it; Dart also polls
        // takeInitialLink on resume, so a link is never lost to a late engine.
        pendingLink?.let { l ->
            channel?.invokeMethod("appLink", l, object : MethodChannel.Result {
                override fun success(r: Any?) { if (pendingLink == l) pendingLink = null }
                override fun error(c: String, m: String?, d: Any?) {}
                override fun notImplemented() {}
            })
        }
    }

    private fun captureLink(i: Intent?) {
        // Only the verified App Link shape reaches Dart; Dart re-validates it.
        val d = i?.data ?: return
        if (i.action == Intent.ACTION_VIEW && d.scheme == "https" &&
            d.host == "otpanda-api.abrahammurciano.workers.dev" &&
            d.userInfo == null && (d.port == -1 || d.port == 443) &&
            d.path == "/app-return") {
            pendingLink = d.toString()
        }
    }

    private fun store(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun activeAlias(): String? = prefs.getString("active", null)?.takeIf { it in aliases }
    private fun pendingAlias(): String = aliases.first { it != activeAlias() }

    private fun publicPoint(alias: String): ByteArray {
        val pub = store().getCertificate(alias).publicKey as ECPublicKey
        fun fix(b: java.math.BigInteger): ByteArray {
            val raw = b.toByteArray().dropWhile { it == 0.toByte() }.toByteArray()
            require(raw.size <= 32)
            return ByteArray(32 - raw.size) + raw
        }
        return byteArrayOf(4) + fix(pub.w.affineX) + fix(pub.w.affineY)
    }

    private fun generate(alias: String) {
        val gen = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
        gen.initialize(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setUserAuthenticationRequired(false)
                .build()
        )
        gen.generateKeyPair()
    }

    /** Active key, created only when none exists. Never replaces a valid key. */
    private fun ensureActive(): ByteArray {
        val a = activeAlias()
        if (a != null && store().containsAlias(a)) return publicPoint(a)
        val fresh = aliases[0]
        deleteKey(fresh); generate(fresh)
        prefs.edit().putString("active", fresh).commit()
        return publicPoint(fresh)
    }

    /** New key under the other alias; the active key stays valid and untouched. */
    private fun beginNew(): ByteArray {
        val p = pendingAlias()
        deleteKey(p); generate(p)
        return publicPoint(p)
    }

    /** After exchange 200: pending becomes active, the old key is deleted. */
    private fun commitNew() {
        val old = activeAlias()
        val p = pendingAlias()
        require(store().containsAlias(p))
        prefs.edit().putString("active", p).commit()
        if (old != null && old != p) deleteKey(old)
    }

    private fun discardNew() = deleteKey(pendingAlias())

    /** ECDSA-SHA256, DER (as the Keystore returns it). */
    private fun sign(message: ByteArray, pending: Boolean): ByteArray {
        val alias = if (pending) pendingAlias() else (activeAlias() ?: error("no key"))
        val key = store().getKey(alias, null) as PrivateKey
        return Signature.getInstance("SHA256withECDSA").run {
            initSign(key); update(message); sign()
        }
    }

    private fun deleteKey(alias: String) {
        val ks = store()
        if (ks.containsAlias(alias)) ks.deleteEntry(alias)
    }
}
