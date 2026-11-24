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

    /** Call only during explicit enrollment authorized by another fresh method.
     * Never recreate a missing key during recovery. Returns public SPKI only.
     */
    fun createForEnrollment(records: NoBackupEnrollmentStore): ByteArray = synchronized(enrollmentLock) {
        check(Build.VERSION.SDK_INT >= 30) { "Android 11 required" }
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
    fun signWithOsVerification(activity: Activity, proof: DeviceProof, clock: () -> Long = System::currentTimeMillis,
        complete: (Result<ByteArray>) -> Unit): CancellationSignal {
        check(Build.VERSION.SDK_INT >= 30) { "Android 11 required" }
        // Sensitive action summaries must be designed and digest-bound before
        // step-up integration. Do not show an opaque digest as informed consent.
        require(proof.purpose != "step-up") { "Bound human-readable action required before step-up wiring" }
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
            finish(Result.failure(IllegalStateException("OS verification cancelled")))
        }
        try {
            val key = store().getKey(alias, null) as? java.security.PrivateKey
                ?: error("Enrolled key unavailable; use another recovery method")
            val operation = Signature.getInstance("SHA256withECDSA").apply { initSign(key) }
            val prompt = BiometricPrompt.Builder(activity)
                .setTitle(when(proof.purpose) {
                    "enroll" -> "Enroll this phone for OTPanda access"
                    "recover-access" -> "Recover OTPanda access"
                    else -> "Confirm OTPanda account action"
                })
                
                .setDescription(if (proof.purpose == "enroll")
                    "Register this phone's signing key for future account access."
                    else "Prove possession of this enrolled phone to request account access.")
                .setAllowedAuthenticators(android.hardware.biometrics.BiometricManager.Authenticators.BIOMETRIC_STRONG or
                    android.hardware.biometrics.BiometricManager.Authenticators.DEVICE_CREDENTIAL)
                .build()
            prompt.authenticate(BiometricPrompt.CryptoObject(operation), cancellation, activity.mainExecutor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationError(code: Int, message: CharSequence) {
                        finish(Result.failure(IllegalStateException("OS verification unavailable or cancelled")))
                    }
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                        if (finished.get() || cancellation.isCanceled) { finish(Result.failure(IllegalStateException("Cancelled"))); return }
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
