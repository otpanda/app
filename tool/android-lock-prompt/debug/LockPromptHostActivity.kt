package app.otpanda.fixture

import android.content.Context
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import app.otpanda.AppLockHost
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
 * Extras: scenario (label), action = unlock | disable, mode = loopback (default) | dart, cancel_ms (dart mode: the Dart controller calls sessionChanged() that long after launch).
 * mode=dart: no loopback. The REAL LocalLockRecoveryHost (with the FAKE api) is registered on the REAL engine messenger, the real AppLockHost stays as MainActivity registered it,
 * and the debug-only channel "lockfx/driver" (config, log, flagPresent) lets the fixture Dart entry (tool/android-lock-prompt/lock_fixture_main.dart) drive the REAL Dart
 * LocalLockController over the real engine channels and report what it saw.
 */
class LockPromptHostActivity : MainActivity() {
    private var t0 = 0L
    private var scenario = "none"
    private var action = "unlock"
    private var mode = "loopback"
    private var cancelMs = 0
    private var loop: Loopback? = null
    private var appLockLoop: Loopback? = null
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
        mode = intent.getStringExtra("mode") ?: "loopback"
        cancelMs = intent.getIntExtra("cancel_ms", 0)
        super.onCreate(savedInstanceState)
        log("onCreate")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine) // real registrations (production default LockApi)
        val deviceId = "fixture-device-not-real"
        if (mode == "dart") { configureDart(flutterEngine, deviceId); return }
        val lockLoop = Loopback(); appLockLoop = lockLoop
        AppLockHost.register(this, lockLoop) // the REAL AppLockHost handler ("enabled" is read through it), before the flag exists
        getSharedPreferences("otpanda_native", Context.MODE_PRIVATE).edit().putString("device_id", deviceId).commit()
        File(noBackupFilesDir, "local-app-lock-v1").let { if (!it.exists()) it.createNewFile() }
        val l = Loopback(); loop = l
        LocalLockRecoveryHost.register(this, l, FakeLockApi(deviceId) { ev, x -> log(ev, x) })
        log("host_ready", "api=fake loopback=1 realHost=1 flag=${File(noBackupFilesDir, "local-app-lock-v1").exists()}")
        appLockLoop?.invoke("app.otpanda/app-lock", "enabled", null) { v, _ -> log("app_lock_enabled", "phase=ready value=$v") }
    }

    /** Dart mode: real Dart controller -> real engine channels -> real host (fake api). Seeds synthetic state BEFORE the Dart entrypoint runs (configureFlutterEngine precedes it). */
    private fun configureDart(e: FlutterEngine, deviceId: String) {
        val messenger = e.dartExecutor.binaryMessenger
        getSharedPreferences("otpanda_native", Context.MODE_PRIVATE).edit().putString("device_id", deviceId).commit()
        File(noBackupFilesDir, "local-app-lock-v1").let { if (!it.exists()) it.createNewFile() }
        LocalLockRecoveryHost.register(this, messenger, FakeLockApi(deviceId) { ev, x -> log(ev, x) })
        io.flutter.plugin.common.MethodChannel(messenger, "lockfx/driver").setMethodCallHandler { call, result ->
            when (call.method) {
                "config" -> result.success(mapOf("mode" to mode, "action" to action, "cancelMs" to cancelMs, "scenario" to scenario))
                "log" -> {
                    val name = call.argument<String>("name") ?: "unnamed"
                    val kv = call.argument<Map<String, String>>("kv") ?: emptyMap()
                    log("dart_" + name.filter { it.isLetterOrDigit() || it == '_' }, kv.entries.joinToString(" ") { (k, v) -> k.filter { c -> c.isLetterOrDigit() || c == '_' } + "=" + v.replace(Regex("\\s"), "_") })
                    result.success(null)
                }
                "flagPresent" -> { val p = File(noBackupFilesDir, "local-app-lock-v1").exists(); log("flag_after", "present=$p source=native_file"); result.success(p) }
                else -> result.notImplemented()
            }
        }
        log("host_ready", "api=fake loopback=0 realMessenger=1 realHost=1 flag=${File(noBackupFilesDir, "local-app-lock-v1").exists()}")
    }

    override fun onResume() {
        super.onResume(); log("onResume")
        if (mode == "loopback" && !started) { started = true; handler.postDelayed({ startAttempt() }, 1500) }
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
            // Actual reads after the outcome: the flag file, and the real AppLockHost's own answer.
            log("flag_after", "present=${File(noBackupFilesDir, "local-app-lock-v1").exists()}")
            appLockLoop?.invoke("app.otpanda/app-lock", "enabled", null) { v, _ -> log("app_lock_enabled", "phase=after value=$v") }
        }
    }

    override fun onStart() { super.onStart(); log("onStart") }
    override fun onPause() { super.onPause(); log("onPause") }
    override fun onStop() { super.onStop(); log("onStop") } // super = real MainActivity.onStop -> LocalLockRecoveryHost.reset()
    override fun onDestroy() { log("onDestroy", "finishing=$isFinishing"); super.onDestroy() }
}

/**
 * Fake begin/finish matching the REAL server's strictness (api src/local-lock-recovery-http.js, src/passkey-service.js, src/passkey-verifier.js): begin body keys exactly
 * {intent, lockGeneration}; finish body keys exactly {intent, lockGeneration, response, token}; lockGeneration 32..128 base64url; token otpda_+55; begin response keys exactly
 * {token, options, expiresAt}; options = simplewebauthn authentication options (rpId, challenge, allowCredentials[{id, transports}], timeout 120000, userVerification required);
 * challenge = base64url SHA-256 (43 chars). The finish response object and its key sets and types are checked. No signature verification (synthetic key).
 */
class FakeLockApi(private val deviceId: String, private val log: (String, String) -> Unit) : LockApi {
    companion object { const val BEARER = "fixture-bearer-not-a-real-token" }
    private var intent: String? = null; private var gen: String? = null; private var token: String? = null; private var challenge: String? = null
    private fun b64u(b: ByteArray) = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(b)
    private fun keys(o: JSONObject) = o.keys().asSequence().toSet()
    private fun bad(ev: String, why: String): ApiResult { log(ev, "ok=0 reason=$why"); return ApiResult(400, "{\"error\":\"invalid_request\"}".toByteArray()) }
    override fun post(path: String, bearer: String, body: ByteArray): ApiResult {
        if (bearer != BEARER) { log("fake_reject", "reason=bearer"); return ApiResult(401, "{\"error\":\"unauthorized\"}".toByteArray()) }
        val j = try { JSONObject(String(body, Charsets.UTF_8)) } catch (e: Exception) { return bad("fake_body", "json") }
        val begin = path.endsWith("/begin"); val ev = if (begin) "fake_begin" else "fake_finish"
        if (keys(j) != (if (begin) setOf("intent", "lockGeneration") else setOf("intent", "lockGeneration", "response", "token"))) return bad(ev, "keys")
        val it = j.opt("intent"); val lg = j.opt("lockGeneration")
        if (it !is String || it !in setOf("local-unlock-once", "local-lock-disable") || lg !is String || !Regex("^[A-Za-z0-9_-]{32,128}$").matches(lg)) return bad(ev, "intent_or_generation")
        if (begin) {
            intent = it; gen = lg
            token = "otpda_" + b64u(ByteArray(41).also { java.security.SecureRandom().nextBytes(it) }).take(55)
            challenge = b64u(java.security.MessageDigest.getInstance("SHA-256").digest(ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }))
            val allow = org.json.JSONArray().put(JSONObject().put("id", b64u("synthetic-fixture-credential".toByteArray())).put("transports", org.json.JSONArray().put("internal")))
            val o = JSONObject().put("token", token).put("options", JSONObject().put("challenge", challenge).put("rpId", "otpanda.github.io")
                .put("allowCredentials", allow).put("timeout", 120000).put("userVerification", "required")).put("expiresAt", System.currentTimeMillis() + 120_000)
            log(ev, "ok=1 intent=$intent")
            return ApiResult(200, o.toString().toByteArray())
        }
        val tk = j.opt("token")
        if (tk !is String || !Regex("^otpda_[A-Za-z0-9_-]{55}$").matches(tk)) return bad(ev, "token_shape")
        val r = j.opt("response") as? JSONObject ?: return bad(ev, "response_type")
        val inner = r.opt("response") as? JSONObject ?: return bad(ev, "inner_type")
        if (keys(r) != setOf("id", "rawId", "type", "clientExtensionResults", "response") || r.opt("type") != "public-key" || r.opt("id") !is String || r.opt("rawId") != r.opt("id") ||
            r.opt("clientExtensionResults") !is JSONObject) return bad(ev, "response_keys")
        if (keys(inner) != setOf("clientDataJSON", "authenticatorData", "signature", "userHandle") ||
            listOf("clientDataJSON", "authenticatorData", "signature").any { inner.opt(it) !is String || (inner.opt(it) as String).isEmpty() } ||
            !(inner.isNull("userHandle") || inner.opt("userHandle") is String)) return bad(ev, "inner_keys")
        val cd = try { JSONObject(String(java.util.Base64.getUrlDecoder().decode(inner.getString("clientDataJSON")), Charsets.UTF_8)) } catch (e: Exception) { null }
        val match = cd?.optString("challenge") == challenge
        val ok = it == intent && lg == gen && tk == token && match
        log(ev, "ok=${if (ok) 1 else 0} challenge_match=${if (match) 1 else 0}")
        if (!ok) return ApiResult(400, "{\"error\":\"invalid_request\"}".toByteArray())
        return ApiResult(200, JSONObject().put("intent", intent).put("lockGeneration", gen).put("deviceId", deviceId).put("generation", 1).toString().toByteArray())
    }
}
