package app.otpanda

import android.app.Activity
import android.os.CancellationSignal
import androidx.credentials.CredentialManager
import androidx.credentials.CredentialManagerCallback
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetCredentialResponse
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import com.google.android.libraries.identity.googleid.GetGoogleIdOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Google flavor: Credential Manager ID token with a server-issued nonce. */
object GoogleFlavor {
    fun register(activity: Activity, messenger: BinaryMessenger) {
        MethodChannel(messenger, "app.otpanda/google").setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(true)
                "idToken" -> {
                    val nonce = call.argument<String>("nonce")
                    val client = call.argument<String>("serverClientId")
                    if (nonce.isNullOrEmpty() || client.isNullOrEmpty()) {
                        result.error("bad_args", "nonce and serverClientId required", null)
                        return@setMethodCallHandler
                    }
                    val option = GetGoogleIdOption.Builder()
                        .setServerClientId(client)
                        .setNonce(nonce)
                        .setFilterByAuthorizedAccounts(false)
                        .build()
                    val request = GetCredentialRequest.Builder().addCredentialOption(option).build()
                    CredentialManager.create(activity).getCredentialAsync(
                        activity, request, CancellationSignal(), activity.mainExecutor,
                        object : CredentialManagerCallback<GetCredentialResponse, GetCredentialException> {
                            override fun onResult(r: GetCredentialResponse) {
                                val c = r.credential
                                if (c is CustomCredential &&
                                    c.type == GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL) {
                                    result.success(GoogleIdTokenCredential.createFrom(c.data).idToken)
                                } else {
                                    result.error("unexpected", "credential type", null)
                                }
                            }
                            override fun onError(e: GetCredentialException) {
                                if (e is GetCredentialCancellationException) result.success(null)
                                else result.error("google", e.javaClass.simpleName, null)
                            }
                        })
                }
                else -> result.notImplemented()
            }
        }
    }
}
