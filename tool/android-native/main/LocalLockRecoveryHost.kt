package app.otpanda

import android.app.Activity
import android.content.Context
import android.os.Build
import android.os.CancellationSignal
import android.view.WindowManager
import androidx.credentials.CredentialManager
import androidx.credentials.CredentialManagerCallback
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetCredentialResponse
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.PublicKeyCredential
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.otpanda.recovery.AssertionResult
import org.otpanda.recovery.Cancellable
import org.otpanda.recovery.HttpsLockApi
import org.otpanda.recovery.LockEffects
import org.otpanda.recovery.LockEnv
import org.otpanda.recovery.LockIntent
import org.otpanda.recovery.LocalLockRecovery
import org.otpanda.recovery.PasskeyAssertion
import java.io.File
import java.util.concurrent.Executors

/**
 * PROPOSAL, not registered. Android glue for org.otpanda.recovery.LocalLockRecovery. Dart can only start an attempt, cancel, and read a coarse outcome.
 * There is no method that disables or unlocks by itself: the lock flag is removed here, by native code, only after the native-validated finish response.
 * Channel "app.otpanda/lock-recovery": start{intent,bearer} -> outcome String (one pending call at a time), cancel -> null, consumeUnlock -> Boolean (one use, 15 s).
 * Host requirements (the primary owns MainActivity and Dart): reset() when the activity stops or is destroyed (pause alone must not cancel), dispose() when the engine detaches,
 * and Dart calls "cancel" on sign-out or any session or device change. That stop and destroy really end an in-flight system prompt is NOT proven; it needs device testing.
 * reset() and every channel method run on the main thread; the transport runs on one daemon thread and posts back through the main looper (never inline).
 */
object LocalLockRecoveryHost {
    private var recovery: LocalLockRecovery? = null
    private var io: java.util.concurrent.ExecutorService? = null
    private var disposed = true
    private var channel: MethodChannel? = null

    /** Ends any attempt (ABORTED, nothing applied). Safe at any time, and after dispose. */
    fun reset() { recovery?.reset() }

    /** Ends the attempt, stops the transport thread, detaches the channel handler. Idempotent. Late results are dropped by the core and by the disposed flag. */
    fun dispose() {
        disposed = true
        recovery?.reset()
        recovery = null
        channel?.setMethodCallHandler(null); channel = null
        io?.shutdownNow(); io = null
    }

    /** Idempotent: a second call (activity recreation, engine reconfiguration) disposes the previous registration first. Call on the main thread. */
    fun register(activity: Activity, messenger: BinaryMessenger) {
        dispose()
        disposed = false
        val thread = Executors.newSingleThreadExecutor { r -> Thread(r, "otpanda-lock-recovery").apply { isDaemon = true } }
        io = thread
        val handler = android.os.Handler(android.os.Looper.getMainLooper())
        // Posts to the main looper. Never runs inline and never touches a destroyed activity: after dispose it drops the work.
        val main = java.util.concurrent.Executor { task -> if (!disposed) handler.post { if (!disposed) task.run() } }
        val rec = LocalLockRecovery(HttpsLockApi(), Passkeys(activity), Effects(activity), Env(activity), thread, main)
        recovery = rec
        val ch = MethodChannel(messenger, "app.otpanda/lock-recovery")
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val intent = LockIntent.entries.firstOrNull { it.wire == call.argument<String>("intent") }
                    val bearer = call.argument<String>("bearer")
                    if (Build.VERSION.SDK_INT < 30 || intent == null || bearer == null) { result.error("invalid", null, null); return@setMethodCallHandler }
                    // The core completes each attempt exactly once. A dead engine can still throw here; that must never crash or change state.
                    rec.start(intent, bearer) { outcome -> try { result.success(outcome.name) } catch (_: Exception) { } }
                }
                "cancel" -> { rec.reset(); result.success(null) }
                "consumeUnlock" -> result.success(rec.consumeUnlock())
                else -> result.notImplemented()
            }
        }
    }

    private class Env(private val activity: Activity) : LockEnv {
        private val random = java.security.SecureRandom()
        override fun nowMs() = System.currentTimeMillis()
        override fun elapsedMs() = android.os.SystemClock.elapsedRealtime()
        override fun random32() = ByteArray(32).also { random.nextBytes(it) }
        // The same native store MainActivity uses for the enrolled device id.
        override fun deviceId(): String? = activity.getSharedPreferences("otpanda_native", Context.MODE_PRIVATE).getString("device_id", null)
    }

    /** Mirrors AppLockHost's flag and secure-window handling. Disable succeeds only when the flag is verifiably gone. */
    private class Effects(private val activity: Activity) : LockEffects {
        private val flag get() = File(activity.noBackupFilesDir, "local-app-lock-v1")
        override fun lockEnabled() = flag.exists()
        override fun disable(): Boolean = try {
            if (flag.exists() && !flag.delete()) false else {
                AppLockHost.reset(); activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE); !flag.exists()
            }
        } catch (_: Exception) { false }
    }

    private class Passkeys(private val activity: Activity) : PasskeyAssertion {
        override fun get(requestJson: String, done: (AssertionResult) -> Unit): Cancellable {
            val signal = CancellationSignal()
            val request = GetCredentialRequest.Builder().addCredentialOption(GetPublicKeyCredentialOption(requestJson)).build()
            CredentialManager.create(activity).getCredentialAsync(activity, request, signal, activity.mainExecutor,
                object : CredentialManagerCallback<GetCredentialResponse, GetCredentialException> {
                    override fun onResult(r: GetCredentialResponse) {
                        val c = r.credential
                        done(if (c is PublicKeyCredential) AssertionResult.Json(c.authenticationResponseJson) else AssertionResult.Unavailable)
                    }
                    override fun onError(e: GetCredentialException) {
                        done(if (e is GetCredentialCancellationException) AssertionResult.UserCancelled else AssertionResult.Unavailable)
                    }
                })
            return Cancellable { signal.cancel() }
        }
    }
}
