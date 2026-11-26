package app.otpanda.fixture

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.util.Base64
import androidx.credentials.GetCredentialResponse
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.PublicKeyCredential
import androidx.credentials.provider.PendingIntentHandler
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.ECGenParameterSpec

/** DEBUG-ONLY. Builds a synthetic WebAuthn-shaped assertion signed by a throwaway key generated in memory on every call (never stored, never a user key). */
class SyntheticAssertionActivity : Activity() {
    companion object { const val ACTION = "app.otpanda.fixture.SYNTHETIC_GET_PASSKEY" }
    private fun b64u(b: ByteArray) = Base64.encodeToString(b, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
    override fun onCreate(s: Bundle?) {
        super.onCreate(s)
        android.util.Log.i("LOCKFX", "ev=provider_selected")
        val req = PendingIntentHandler.retrieveProviderGetCredentialRequest(intent)
        val opt = req?.credentialOptions?.firstOrNull() as? GetPublicKeyCredentialOption
        if (opt == null) { setResult(RESULT_CANCELED); finish(); return }
        val challenge = Regex("\"challenge\"\\s*:\\s*\"([^\"]+)\"").find(opt.requestJson)?.groupValues?.get(1) ?: ""
        val clientData = "{\"type\":\"webauthn.get\",\"challenge\":\"$challenge\",\"origin\":\"android:apk-key-hash:fixture\"}".toByteArray()
        val rpIdHash = MessageDigest.getInstance("SHA-256").digest("otpanda.github.io".toByteArray())
        val authData = rpIdHash + byteArrayOf(0x05, 0, 0, 0, 1) // UP + UV flags, counter 1
        val kp = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
        val sig = Signature.getInstance("SHA256withECDSA").apply { initSign(kp.private); update(authData + MessageDigest.getInstance("SHA-256").digest(clientData)) }.sign()
        val id = b64u("synthetic-fixture-credential".toByteArray())
        val json = "{\"id\":\"$id\",\"rawId\":\"$id\",\"type\":\"public-key\",\"authenticatorAttachment\":\"platform\",\"clientExtensionResults\":{}," +
            "\"response\":{\"clientDataJSON\":\"${b64u(clientData)}\",\"authenticatorData\":\"${b64u(authData)}\",\"signature\":\"${b64u(sig)}\",\"userHandle\":\"${b64u("fixture".toByteArray())}\"}}"
        val result = Intent()
        PendingIntentHandler.setGetCredentialResponse(result, GetCredentialResponse(PublicKeyCredential(json)))
        setResult(RESULT_OK, result); finish()
    }
}
