package app.otpanda.fixture

import android.app.Activity
import android.os.Bundle
import android.os.CancellationSignal
import android.os.SystemClock
import android.util.Log
import android.widget.TextView
import androidx.credentials.CredentialManager
import androidx.credentials.CredentialManagerCallback
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetCredentialResponse
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.PublicKeyCredential
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import org.otpanda.recovery.ApiResult
import org.otpanda.recovery.AssertionResult
import org.otpanda.recovery.Cancellable
import org.otpanda.recovery.LocalLockRecovery
import org.otpanda.recovery.LockApi
import org.otpanda.recovery.LockEffects
import org.otpanda.recovery.LockEnv
import org.otpanda.recovery.LockIntent
import org.otpanda.recovery.PasskeyAssertion
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/**
 * DEBUG-ONLY runtime fixture. Lives only in the debug source set (installed by install-fixture.py), never in main or release.
 * Shows the real Credential Manager UI through the real LocalLockRecovery core, with a FAKE begin transport (no network, no server, no real key,
 * no account). It observes onPause/onStop/onResume/onDestroy, the cancel and the result, and logs them under tag LOCKFX with elapsed milliseconds.
 * Extras: scenario (label only), mimic=1 makes onStop/onDestroy call recovery.reset() exactly like MainActivity in the composed branch, mimic=0 only observes.
 * The runner marks adb-driven user actions in the same log (tag LOCKFX, ev=mark) so a prompt-caused stop and a user-caused stop are distinguishable.
 */
class LockPromptFixtureActivity : Activity() {
    private var recovery: LocalLockRecovery? = null
    private var mimic = false
    private var scenario = "none"
    private var t0 = 0L
    private var starts = 0
    private val io = Executors.newSingleThreadExecutor { r -> Thread(r, "lockfx-io").apply { isDaemon = true } }
    private val handler = android.os.Handler(android.os.Looper.getMainLooper())
    private val main = Executor { handler.post(it) }

    private fun log(ev: String, extra: String = "") {
        Log.i("LOCKFX", "ev=$ev t=${SystemClock.elapsedRealtime() - t0} scenario=$scenario mimic=${if (mimic) 1 else 0} pid=${android.os.Process.myPid()} $extra".trim())
    }

    private class FakeApi : LockApi {
        override fun post(path: String, bearer: String, body: ByteArray): ApiResult {
            if (path.endsWith("/begin")) {
                val now = System.currentTimeMillis()
                val token = "otpda_" + "A".repeat(55)
                val challenge = "B".repeat(43)
                val id = "C".repeat(22)
                val json = "{\"token\":\"$token\",\"expiresAt\":${now + 100_000},\"options\":{\"rpId\":\"otpanda.github.io\",\"userVerification\":\"required\"," +
                    "\"challenge\":\"$challenge\",\"allowCredentials\":[{\"type\":\"public-key\",\"id\":\"$id\"}]}}"
                return ApiResult(200, json.toByteArray(Charsets.UTF_8))
            }
            // The fixture never finishes a ceremony. Reaching here would mean a synthetic assertion was produced, which cannot happen without a real key.
            throw org.otpanda.recovery.ApiUnreachable()
        }
    }

    private inner class FakeEffects : LockEffects {
        override fun lockEnabled() = true
        override fun disable() = false
    }

    private class FakeEnv : LockEnv {
        override fun nowMs() = System.currentTimeMillis()
        override fun elapsedMs() = SystemClock.elapsedRealtime()
        override fun random32() = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
        override fun deviceId(): String? = "fixture-device-not-real"
    }

    /** Same Credential Manager call as app.otpanda.LocalLockRecoveryHost.Passkeys (tool/check_lock_prompt_fixture.py compares the call lines), plus logging. */
    private inner class Passkeys : PasskeyAssertion {
        override fun get(requestJson: String, done: (AssertionResult) -> Unit): Cancellable {
            val signal = CancellationSignal()
            val request = GetCredentialRequest.Builder().addCredentialOption(GetPublicKeyCredentialOption(requestJson)).build()
            log("prompt_requested")
            CredentialManager.create(this@LockPromptFixtureActivity).getCredentialAsync(this@LockPromptFixtureActivity, request, signal, this@LockPromptFixtureActivity.mainExecutor,
                object : CredentialManagerCallback<GetCredentialResponse, GetCredentialException> {
                    override fun onResult(r: GetCredentialResponse) {
                        val c = r.credential
                        log("prompt_result", "kind=${if (c is PublicKeyCredential) "credential" else "other"}")
                        done(if (c is PublicKeyCredential) AssertionResult.Json(c.authenticationResponseJson) else AssertionResult.Unavailable)
                    }
                    override fun onError(e: GetCredentialException) {
                        log("prompt_error", "class=${e.javaClass.simpleName} type=${e.type.substringAfterLast('.')}")
                        done(if (e is GetCredentialCancellationException) AssertionResult.UserCancelled else AssertionResult.Unavailable)
                    }
                })
            return Cancellable { log("prompt_cancel_signal"); signal.cancel() }
        }
    }

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        t0 = SystemClock.elapsedRealtime()
        setContentView(TextView(this).apply { text = "otpanda lock-prompt fixture (synthetic, debug only)"; textSize = 18f; setPadding(48, 96, 48, 48) })
        recovery = LocalLockRecovery(FakeApi(), Passkeys(), FakeEffects(), FakeEnv(), io, main)
        readIntent()
        log("onCreate")
        startAttempt()
    }

    override fun onNewIntent(i: android.content.Intent) {
        super.onNewIntent(i); setIntent(i)
    }

    private fun readIntent() {
        scenario = intent.getStringExtra("scenario") ?: "none"
        mimic = intent.getIntExtra("mimic", 0) == 1
    }

    private fun startAttempt() {
        starts++
        log("attempt_start", "n=$starts")
        recovery?.start(LockIntent.UNLOCK_ONCE, "fixture-bearer-not-a-real-token") { outcome -> log("outcome", "value=${outcome.name}") }
    }

    override fun onStart() { super.onStart(); log("onStart") }
    override fun onResume() { super.onResume(); log("onResume") }
    override fun onPause() { super.onPause(); log("onPause") }
    override fun onWindowFocusChanged(has: Boolean) { super.onWindowFocusChanged(has); log("focus", "has=$has") }
    override fun onStop() {
        super.onStop(); log("onStop")
        if (mimic) { log("mimic_reset"); recovery?.reset() }
    }
    override fun onDestroy() {
        log("onDestroy", "finishing=$isFinishing")
        if (mimic) recovery?.reset()
        io.shutdownNow()
        super.onDestroy()
    }
}
