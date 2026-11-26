package app.otpanda.fixture

import android.content.Context
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import app.otpanda.MainActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import org.json.JSONObject
import org.otpanda.recovery.ApiResult
import org.otpanda.recovery.LockApi
import org.otpanda.recovery.LockIntent
import app.otpanda.LocalLockRecoveryHost
import java.io.File
import java.nio.ByteBuffer

/**
 * DEBUG-ONLY (debug source set, installed by install-fixture.py). EXTENDS the real MainActivity: the real engine, the real AppLockHost and every real lifecycle hook
 * (onStop/onDestroy reset, cleanUpFlutterEngine dispose, all registrations) run unchanged. The only substitution: after the real configureFlutterEngine, the REAL
 * LocalLockRecoveryHost is registered again (register is idempotent) with a FAKE LockApi on an in-process loopback messenger, so this fixture can drive the real
 * channel handler "app.otpanda/lock-recovery" without Dart and without network. Real Passkeys (Credential Manager), real Effects (flag file + AppLockHost) and real Env.
 * Synthetic state only: a fake device id and the real flag file location. No real account, key, seed or server.
 * Extras: scenario (label), action = unlock | disable.
 */
class LockPromptHostActivity : MainActivity() {
    private var t0 = 0L
    private var scenario = "none"
    private var action = "unlock"
    private var loop: Loopback? = null
    private var started = false
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())

    private fun log(ev: String, extra: String = "") {
        Log.i("LOCKFX", "ev=$ev t=${SystemClock.elapsedRealtime() - t0} scenario=$scenario pid=${android.os.Process.myPid()} $extra".trim())
    }

    private class Loopback : BinaryMessenger {
        private val handlers = HashMap<String, BinaryMessenger.BinaryMessageHandler>()
        override fun send(channel: String, message: ByteBuffer?) {}
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) { callback?.reply(null) }
        override fun setMessageHandler(channel: String, h: BinaryMessenger.BinaryMessageHandler?) { if (h == null) handlers.remove(channel) else handlers[channel] = h }
        fun invoke(channel: String, method: String, args: Any?, done: (Any?, String?) -> Unit) {
            val h = handlers[channel] ?: return done(null, "no_handler")
            val msg = StandardMethodCodec.INSTANCE.encodeMethodCall(MethodCall(method, args)); msg.rewind()
            h.onMessage(msg) { reply ->
                try { reply!!.rewind(); done(StandardMethodCodec.INSTANCE.decodeEnvelope(reply), null) }
                catch (e: io.flutter.plugin.common.FlutterException) { done(null, e.code) }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        t0 = SystemClock.elapsedRealtime()
        scenario = intent.getStringExtra("scenario") ?: "none"
        action = intent.getStringExtra("action") ?: "unlock"
        super.onCreate(savedInstanceState)
        log("onCreate")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine) // real registrations (production default LockApi)
        val deviceId = "fixture-device-not-real"
        getSharedPreferences("otpanda_native", Context.MODE_PRIVATE).edit().putString("device_id", deviceId).commit()
        File(noBackupFilesDir, "local-app-lock-v1").let { if (!it.exists()) it.createNewFile() }
        val l = Loopback(); loop = l
        LocalLockRecoveryHost.register(this, l, FakeLockApi(deviceId) { ev, x -> log(ev, x) })
        log("host_ready", "api=fake loopback=1 realHost=1 flag=${File(noBackupFilesDir, "local-app-lock-v1").exists()}")
    }

    override fun onResume() {
        super.onResume(); log("onResume")
        if (!started) { started = true; handler.postDelayed({ startAttempt() }, 1500) }
    }

    private fun startAttempt() {
        val l = loop ?: return
        val wire = if (action == "disable") LockIntent.DISABLE.wire else LockIntent.UNLOCK_ONCE.wire
        log("attempt_start", "intent=$wire")
        l.invoke("app.otpanda/lock-recovery", "start", mapOf("intent" to wire, "bearer" to FakeLockApi.BEARER)) { r, err ->
            log("outcome", "value=${r ?: "error_$err"}")
            if (r == "UNLOCK_GRANTED") {
                l.invoke("app.otpanda/lock-recovery", "consumeUnlock", null) { a, _ ->
                    l.invoke("app.otpanda/lock-recovery", "consumeUnlock", null) { b, _ -> log("consume_unlock", "first=$a second=$b") }
                }
            }
            if (r == "DISABLED") log("flag_after", "present=${File(noBackupFilesDir, "local-app-lock-v1").exists()}")
        }
    }

    override fun onStart() { super.onStart(); log("onStart") }
    override fun onPause() { super.onPause(); log("onPause") }
    override fun onStop() { super.onStop(); log("onStop") } // super = real MainActivity.onStop -> LocalLockRecoveryHost.reset()
    override fun onDestroy() { log("onDestroy", "finishing=$isFinishing"); super.onDestroy() }
}

/** Fake begin/finish with the REAL wire shapes LocalLockRecovery validates. Validates the finish body structurally and checks the challenge round-trip. No crypto verification (synthetic key). */
class FakeLockApi(private val deviceId: String, private val log: (String, String) -> Unit) : LockApi {
    companion object { const val BEARER = "fixture-bearer-not-a-real-token" }
    private var intent: String? = null; private var gen: String? = null; private var token: String? = null; private var challenge: String? = null
    private fun b64u(b: ByteArray) = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(b)
    override fun post(path: String, bearer: String, body: ByteArray): ApiResult {
        if (bearer != BEARER) { log("fake_reject", "reason=bearer"); return ApiResult(401, "{}".toByteArray()) }
        val j = try { JSONObject(String(body, Charsets.UTF_8)) } catch (e: Exception) { return ApiResult(400, "{}".toByteArray()) }
        if (path.endsWith("/begin")) {
            intent = j.optString("intent"); gen = j.optString("lockGeneration")
            if (intent !in setOf("local-unlock-once", "local-lock-disable") || !Regex("^[A-Za-z0-9_-]{43}$").matches(gen!!)) { log("fake_begin", "ok=0"); return ApiResult(400, "{}".toByteArray()) }
            token = "otpda_" + b64u(ByteArray(41).also { java.security.SecureRandom().nextBytes(it) }).take(55)
            challenge = b64u(ByteArray(32).also { java.security.SecureRandom().nextBytes(it) })
            val o = JSONObject().put("token", token).put("expiresAt", System.currentTimeMillis() + 100_000).put("options", JSONObject()
                .put("rpId", "otpanda.github.io").put("userVerification", "required").put("challenge", challenge)
                .put("allowCredentials", org.json.JSONArray().put(JSONObject().put("type", "public-key").put("id", b64u("synthetic-fixture-credential".toByteArray())))))
            log("fake_begin", "ok=1 intent=$intent")
            return ApiResult(200, o.toString().toByteArray())
        }
        val resp = j.optJSONObject("response")?.optJSONObject("response")
        val cd = try { JSONObject(String(java.util.Base64.getUrlDecoder().decode(resp?.optString("clientDataJSON") ?: ""), Charsets.UTF_8)) } catch (e: Exception) { null }
        val ok = j.optString("intent") == intent && j.optString("lockGeneration") == gen && j.optString("token") == token &&
            resp != null && resp.optString("authenticatorData").isNotEmpty() && resp.optString("signature").isNotEmpty() && cd?.optString("challenge") == challenge
        log("fake_finish", "ok=${if (ok) 1 else 0} challenge_match=${if (cd?.optString("challenge") == challenge) 1 else 0}")
        if (!ok) return ApiResult(400, "{}".toByteArray())
        return ApiResult(200, JSONObject().put("intent", intent).put("lockGeneration", gen).put("deviceId", deviceId).put("generation", 1).toString().toByteArray())
    }
}
