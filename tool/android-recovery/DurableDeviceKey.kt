package org.otpanda.recovery

import android.app.Activity
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.util.concurrent.atomic.AtomicBoolean

/** Inactive native primitive. No enrollment, networking or account effect. */
class DurableDeviceKey {
    private val alias = "otpanda.device-proof.v1"
    companion object {
        private val enrollmentLock = Any()
        private val pending = AtomicBoolean(false)
    }
    private fun store() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    fun exists(): Boolean = store().containsAlias(alias)

    /** Public SPKI of the enrolled key, or null when there is none. */
    fun publicKeyOrNull(): ByteArray? = if (exists()) store().getCertificate(alias).publicKey.encoded else null

    /** Call only during explicit enrollment authorized by another fresh method.
     * Never recreate a missing key during recovery. Returns public SPKI only.
     */
    fun createForEnrollment(records: NoBackupEnrollmentStore): ByteArray = synchronized(enrollmentLock) {
        if (Build.VERSION.SDK_INT < 30) throw DeviceProofException("unsupported_os")
        val record = records.read()
        validateEnrollmentCandidate(record, if(exists()) store().getCertificate(alias).publicKey.encoded else null)
        // An interrupted enrollment reuses the same public key. Never delete or
        // replace it because a response was lost. Server must reconcile SPKI.
        if (exists()) {
            val key = store().getKey(alias,null) as java.security.PrivateKey
            val info = java.security.KeyFactory.getInstance("EC","AndroidKeyStore")
                .getKeySpec(key,android.security.keystore.KeyInfo::class.java)
            check(info.isUserAuthenticationRequired && info.userAuthenticationValidityDurationSeconds == -1 &&
                info.userAuthenticationType == (KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL)) { "Existing key policy unavailable or incompatible" }
            return@synchronized store().getCertificate(alias).publicKey.encoded
        }
        val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
        generator.initialize(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(false)
            .setUserAuthenticationParameters(0,
                KeyProperties.AUTH_BIOMETRIC_STRONG or KeyProperties.AUTH_DEVICE_CREDENTIAL)
            .build())
        generator.generateKeyPair().public.encoded
    }

    /** Signs a validated domain-separated challenge, not an arbitrary bearer.
     * Caller owns schema/audience/expiry and fresh authorized challenge retrieval.
     * Returns fixed64byte P1363 ECDSA for the existing server verifier.
     * No callback flag alone authorizes signing: use the OS-returned operation.
     */
    fun signWithOsVerification(activity: Activity, proof: DeviceProof, clock: () -> Long = System::currentTimeMillis, displayText: String? = null,
        complete: (Result<ByteArray>) -> Unit): CancellationSignal {
        if (Build.VERSION.SDK_INT < 30) throw DeviceProofException("unsupported_os")
        // Sensitive action summaries must be designed and digest-bound before
        // step-up integration. Do not show an opaque digest as informed consent.
        // Step-up needs the readable text the caller already validated against
        // the hashed action; it is shown verbatim as the prompt description.
        if (proof.purpose == "step-up") {
            val t = displayText
            if (t == null || t.isBlank() || t.length > 300 || hasUnsafeChar(t)) throw DeviceProofException("failed")
        }
        val message = proof.message(clock())
        check(pending.compareAndSet(false, true)) { "Verification already pending" }
        val cancellation = CancellationSignal()
        val bytes = message.copyOf()
        val finished = AtomicBoolean(false)
        fun finish(result: Result<ByteArray>) {
            if (finished.compareAndSet(false, true)) { pending.set(false); bytes.fill(0); complete(result) }
            else result.getOrNull()?.fill(0)
        }
        cancellation.setOnCancelListener {
            finish(Result.failure(DeviceProofException("cancelled")))
        }
        try {
            val key = store().getKey(alias, null) as? java.security.PrivateKey
                ?: throw DeviceProofException("key_missing")
            val operation = Signature.getInstance("SHA256withECDSA").apply {
                try { initSign(key) } catch (_: android.security.keystore.KeyPermanentlyInvalidatedException) {
                    throw DeviceProofException("key_invalidated")
                }
            }
            val prompt = BiometricPrompt.Builder(activity)
                .setTitle(when(proof.purpose) {
                    "enroll" -> "Enroll this phone for OTPanda access"
                    "recover-access" -> "Recover OTPanda access"
                    else -> "Confirm OTPanda account action"
                })
                
                .setDescription(when (proof.purpose) {
                    "enroll" -> "Register this phone's signing key for future account access."
                    "step-up" -> displayText!!
                    else -> "Prove possession of this enrolled phone to request account access."
                })
                .setAllowedAuthenticators(android.hardware.biometrics.BiometricManager.Authenticators.BIOMETRIC_STRONG or
                    android.hardware.biometrics.BiometricManager.Authenticators.DEVICE_CREDENTIAL)
                .build()
            prompt.authenticate(BiometricPrompt.CryptoObject(operation), cancellation, activity.mainExecutor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationError(code: Int, message: CharSequence) {
                        finish(Result.failure(DeviceProofException(when (code) {
                            BiometricPrompt.BIOMETRIC_ERROR_CANCELED, BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED,
                            13 /* BIOMETRIC_ERROR_NEGATIVE_BUTTON */ -> "cancelled"
                            BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT, BiometricPrompt.BIOMETRIC_ERROR_LOCKOUT_PERMANENT -> "locked_out"
                            BiometricPrompt.BIOMETRIC_ERROR_NO_DEVICE_CREDENTIAL, BiometricPrompt.BIOMETRIC_ERROR_NO_BIOMETRICS,
                            BiometricPrompt.BIOMETRIC_ERROR_HW_NOT_PRESENT -> "no_secure_lock"
                            BiometricPrompt.BIOMETRIC_ERROR_TIMEOUT -> "expired"
                            else -> "failed"
                        })))
                    }
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                        if (finished.get() || cancellation.isCanceled) { finish(Result.failure(DeviceProofException("cancelled"))); return }
                        try {
                            proof.message(clock()) // Fail if the prompt outlived the challenge.
                            val verified = result.cryptoObject?.signature ?: error("Verified operation required")
                            check(verified === operation) { "Unexpected operation" }
                            verified.update(bytes)
                            finish(Result.success(derToP1363(verified.sign())))
                        } catch (error: Exception) { finish(Result.failure(error)) }
                    }
                })
        } catch (error: Exception) { finish(Result.failure(error)) }
        return cancellation
    }
}

/** Control, zero-width and bidi-override characters never appear in prompt text. */
internal fun hasUnsafeChar(t: String): Boolean = t.any {
    it.code <= 0x1f || it.code in 0x7f..0x9f || it.code in 0x200b..0x200f || it.code == 0x2028 || it.code == 0x2029 || it.code == 0x061c ||
        it.code in 0x202a..0x202e || it.code in 0x2066..0x2069 || it.code == 0xfeff
}
