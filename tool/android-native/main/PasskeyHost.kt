package app.otpanda

import android.app.Activity
import android.os.Build
import android.os.CancellationSignal
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

/**
 * Passkey assertion for server step-up ceremonies, in both flavors. Uses only
 * androidx.credentials (no Google Play Services classes are linked here).
 * Android 14+ routes to the system's credential providers. Below that, a
 * provider exists only when the google flavor adds the Play Services bridge,
 * detected by class name so the F-Droid build never references it.
 * The Keystore renewal key is never used for this.
 */
object PasskeyHost {
    private fun providerAvailable(): Boolean {
        if (Build.VERSION.SDK_INT >= 34) return true
        return try {
            Class.forName("androidx.credentials.playservices.CredentialProviderPlayServicesImpl")
            true
        } catch (e: ClassNotFoundException) {
            false
        }
    }

    fun register(activity: Activity, messenger: BinaryMessenger) {
        MethodChannel(messenger, "app.otpanda/passkey").setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(providerAvailable())
                "get" -> {
                    val json = call.argument<String>("requestJson")
                    if (json.isNullOrEmpty() || json.length > 16384) {
                        result.error("bad_args", "requestJson required", null)
                        return@setMethodCallHandler
                    }
                    if (!providerAvailable()) {
                        result.error("unavailable", "no passkey provider", null)
                        return@setMethodCallHandler
                    }
                    val request = GetCredentialRequest.Builder()
                        .addCredentialOption(GetPublicKeyCredentialOption(json)).build()
                    CredentialManager.create(activity).getCredentialAsync(
                        activity, request, CancellationSignal(), activity.mainExecutor,
                        object : CredentialManagerCallback<GetCredentialResponse, GetCredentialException> {
                            override fun onResult(r: GetCredentialResponse) {
                                val c = r.credential
                                if (c is PublicKeyCredential) result.success(c.authenticationResponseJson)
                                else result.error("unexpected", "credential type", null)
                            }
                            override fun onError(e: GetCredentialException) {
                                if (e is GetCredentialCancellationException) result.success(null)
                                else result.error("passkey", e.javaClass.simpleName, null)
                            }
                        })
                }
                else -> result.notImplemented()
            }
        }
    }
}
