package app.otpanda

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.hardware.biometrics.BiometricManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.otpanda.recovery.ActivityProofOperation
import org.otpanda.recovery.DeviceProof
import org.otpanda.recovery.DeviceProofException
import org.otpanda.recovery.DurableDeviceKey
import org.otpanda.recovery.EnrollmentRecord
import org.otpanda.recovery.NoBackupEnrollmentStore
import org.otpanda.recovery.NoBackupPendingStore

/**
 * Channel host for the OS-gated enrolled-device key (tool/android-recovery).
 * Nothing in the Flutter app calls it yet, so no key is created and nothing is
 * enrolled. It never deletes or replaces a key. Step-up is refused here.
 * Android 11+ only; below that every call answers unsupported_os.
 */
object DeviceProofHost {
    private const val NAME = "app.otpanda/device-proof"

    fun register(activity: Activity, messenger: BinaryMessenger) {
        val keys = DurableDeviceKey()
        val store = NoBackupEnrollmentStore(activity.applicationContext)
        MethodChannel(messenger, NAME).setMethodCallHandler { call, result ->
            try {
                handle(activity, keys, store, call, result)
            } catch (e: DeviceProofException) {
                result.error(e.code, null, null)
            } catch (e: Exception) {
                result.error("failed", e.javaClass.simpleName, null)
            }
        }
    }

    private fun slotOf(call: MethodCall): String =
        if (call.argument<String>("slot") == "add") "add" else "enroll"

    /** Step-up signing is not released. Flip only with the settled contract. */
    const val STEP_UP_ENABLED = false

    /** Pure: the availability answer for an SDK level and the lock/biometric state. */
    internal fun availability(sdk: Int, secure: Boolean, canAuthenticate: Int): String = when {
        sdk < 30 -> "unsupported_os"
        !secure -> "no_secure_lock"
        canAuthenticate == BiometricManager.BIOMETRIC_SUCCESS -> "available"
        // Busy hardware or a pending security update is temporary, not a missing lock.
        canAuthenticate == BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE ||
            canAuthenticate == BiometricManager.BIOMETRIC_ERROR_SECURITY_UPDATE_REQUIRED ||
            canAuthenticate == -1 /* BIOMETRIC_STATUS_UNKNOWN */ -> "temporarily_unavailable"
        else -> "no_secure_lock"
    }

    private fun availability(activity: Activity): String {
        if (Build.VERSION.SDK_INT < 30) return "unsupported_os"
        val keyguard = activity.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        val manager = activity.getSystemService(BiometricManager::class.java)
        val can = manager.canAuthenticate(
            BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL,
        )
        return availability(Build.VERSION.SDK_INT, keyguard.isDeviceSecure, can)
    }

    private fun handle(
        activity: Activity, keys: DurableDeviceKey, store: NoBackupEnrollmentStore,
        call: MethodCall, result: MethodChannel.Result,
    ) {
        when (call.method) {
            "availability" -> result.success(availability(activity))
            "publicKey" -> {
                if (Build.VERSION.SDK_INT < 30) throw DeviceProofException("unsupported_os")
                // Read-only: never creates a key, shows no prompt.
                result.success(keys.publicKeyOrNull()?.let { android.util.Base64.encodeToString(it, android.util.Base64.NO_WRAP) })
            }
            "pendingRead" -> result.success(NoBackupPendingStore(activity, slotOf(call)).read())
            "pendingWrite" -> {
                val rec = call.argument<String>("record") ?: throw DeviceProofException("failed")
                NoBackupPendingStore(activity, slotOf(call)).write(rec)
                result.success(true)
            }
            "pendingClear" -> { NoBackupPendingStore(activity, slotOf(call)).clear(); result.success(true) }
            "hasKey" -> {
                if (Build.VERSION.SDK_INT < 30) throw DeviceProofException("unsupported_os")
                result.success(keys.exists())
            }
            "createKeyForEnrollment" -> {
                when (availability(activity)) {
                    "unsupported_os" -> throw DeviceProofException("unsupported_os")
                    "no_secure_lock" -> throw DeviceProofException("no_secure_lock")
                    "temporarily_unavailable" -> throw DeviceProofException("temporarily_unavailable")
                }
                result.success(keys.createForEnrollment(store))
            }
            "saveConfirmed" -> {
                // Only after a typed server confirmation for exactly this key.
                val owner = call.argument<String>("ownerId") ?: throw DeviceProofException("failed")
                val keyId = call.argument<String>("keyId") ?: throw DeviceProofException("failed")
                val spki = keys.publicKeyOrNull() ?: throw DeviceProofException("key_missing")
                store.saveConfirmed(EnrollmentRecord(owner, keyId, EnrollmentRecord.hash(spki)))
                result.success(true)
            }
            "sign" -> sign(activity, keys, call, result)
            else -> result.notImplemented()
        }
    }

    private fun sign(activity: Activity, keys: DurableDeviceKey, call: MethodCall, result: MethodChannel.Result) {
        fun s(k: String) = call.argument<String>(k) ?: throw DeviceProofException("failed")
        val purpose = s("purpose")
        // Step-up stays OFF (compile-time) until the canonical contract is
        // released. When on, it needs Dart-validated readable text.
        if (purpose != "enroll" && !(STEP_UP_ENABLED && purpose == "step-up")) throw DeviceProofException("failed")
        val displayText = if (purpose == "step-up") s("displayText") else null
        val expiresAt = (call.argument<Number>("expiresAt") ?: throw DeviceProofException("failed")).toLong()
        if (expiresAt <= System.currentTimeMillis()) throw DeviceProofException("expired")
        val proof = DeviceProof(
            purpose, s("ownerId"), s("keyId"),
            (call.argument<Number>("generation") ?: throw DeviceProofException("failed")).toLong(),
            s("challenge"), s("actionDigest"), expiresAt,
        )
        // The host signs only the bytes the Flutter side computed itself.
        val sent = call.argument<ByteArray>("message") ?: throw DeviceProofException("failed")
        if (!proof.message(System.currentTimeMillis()).contentEquals(sent)) throw DeviceProofException("failed")
        ActivityProofOperation(activity, keys).start(proof, displayText) { r ->
            r.fold(
                { result.success(it) },
                { e -> result.error((e as? DeviceProofException)?.code ?: "failed", null, null) },
            )
        }
    }
}
