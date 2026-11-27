package app.otpanda.seedfixture

import app.otpanda.MainActivity
import app.otpanda.SeedCustodyHost
import app.otpanda.WrappingKeyHost
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.otpanda.totp.SeedSyncWire
import org.otpanda.totp.SyncPurpose
import java.math.BigInteger
import java.security.KeyFactory
import java.security.Signature
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec

/** Debug source set only. No API, account, real secret or alternate custody. */
class SeedHostActivity : MainActivity() {
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        SeedCustodyHost.register(this, engine.dartExecutor.binaryMessenger)
        WrappingKeyHost.register(this, engine.dartExecutor.binaryMessenger)
        MethodChannel(engine.dartExecutor.binaryMessenger, "seedfx/driver").setMethodCallHandler { call, result ->
            when(call.method) {
                "save" -> { java.io.File(noBackupFilesDir,"seedfx-public").writeText(call.arguments as String); result.success(null) }
                "load" -> result.success(java.io.File(noBackupFilesDir,"seedfx-public").readText())
                "seal" -> {
                    try { result.success(SyntheticSeedSealer.seal(call.argument<String>("ephemeral")!!)) }
                    catch (_: Throwable) { result.error("FIXTURE_SEAL",null,null) }
                }
                "config" -> result.success(intent.getStringExtra("phase") ?: "create")
                "verify" -> {
                    try {
                        val pub = call.argument<ByteArray>("publicKey")!!
                        val keyId = call.argument<String>("keyId")!!
                        val challenge = call.argument<String>("challenge")!!
                        val expires = call.argument<Number>("expiresAt")!!.toLong()
                        val sig = call.argument<String>("signature")!!
                        val publicKey = KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(BigInteger(1,pub.copyOfRange(1,33)), BigInteger(1,pub.copyOfRange(33,65))), SeedSyncWire.jcaParams()))
                        val message = SeedSyncWire.proofMessage(SyncPurpose.STATUS,mapOf("keyId" to keyId,"challenge" to challenge,"expiresAt" to expires))
                        val valid = Signature.getInstance("SHA256withECDSA").run {
                            initVerify(publicKey); update(message); verify(SeedSyncWire.p1363ToDer(SeedSyncWire.unb64(sig,64)))
                        }
                        result.success(valid)
                    } catch (_: Throwable) { result.success(false) }
                }
                "log" -> {
                    // Fixed labels and booleans only. No identity, key, seed or proof output.
                    val label = call.argument<String>("label") ?: "missing"
                    if (label.matches(Regex("[a-z_]{1,64}"))) android.util.Log.i("SEEDFX", "CHECK $label ${call.argument<Boolean>("ok") == true}")
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
