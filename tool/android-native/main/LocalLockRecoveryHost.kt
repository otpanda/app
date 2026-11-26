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
 * Host rules: call reset() from MainActivity.onStop and onDestroy (pause alone does not cancel), and Dart calls "cancel" on sign-out or any session or device change.
 * reset() and every method run on the main thread; the transport runs on a single background thread and posts back to main.
 */
object LocalLockRecoveryHost {
    private var recovery: LocalLockRecovery? = null
    fun reset() { recovery?.reset() }

    fun register(activity: Activity, messenger: BinaryMessenger) {
        reset()
        val io = Executors.newSingleThreadExecutor()
        val main = java.util.concurrent.Executor { activity.runOnUiThread(it) }
        val rec = LocalLockRecovery(HttpsLockApi(), Passkeys(activity), Effects(activity), Env(activity), io, main)
        recovery = rec
        MethodChannel(messenger, "app.otpanda/lock-recovery").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val intent = LockIntent.entries.firstOrNull { it.wire == call.argument<String>("intent") }
                    val bearer = call.argument<String>("bearer")
                    if (Build.VERSION.SDK_INT < 30 || intent == null || bearer == null) { result.error("invalid", null, null); return@setMethodCallHandler }
                    rec.start(intent, bearer) { outcome -> result.success(outcome.name) }
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
                activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE); !flag.exists()
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
