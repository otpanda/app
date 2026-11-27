package app.otpanda.seedfixture

import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import android.util.Base64

/** DEBUG-ONLY synthetic server half. Fixed public RFC6238 test seed, never an
 * account seed. Independent AAD/HKDF construction, no production wire helper.
 * Replies contain sealed bytes only. Nothing here imports a Keystore seed.
 */
object SyntheticSeedSealer {
    private fun b64(b: ByteArray)=Base64.encodeToString(b,Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
    private fun sha(b: ByteArray)=MessageDigest.getInstance("SHA-256").digest(b)
    private fun hex(b: ByteArray)=b.joinToString(""){"%02x".format(it)}
    private fun hmac(k:ByteArray,b:ByteArray)=Mac.getInstance("HmacSHA256").run { init(SecretKeySpec(k,"HmacSHA256"));doFinal(b) }
    private fun fix(n:BigInteger)=n.toByteArray().let { if(it.size>32) it.copyOfRange(it.size-32,it.size) else ByteArray(32-it.size)+it }
    fun seal(ephemeral: String): Map<String,String> {
        val raw=Base64.decode(ephemeral,Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
        require(raw.size==65 && raw[0]==4.toByte() && b64(raw)==ephemeral)
        val kp=KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
        val params=(kp.public as ECPublicKey).params
        val peer=KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(BigInteger(1,raw.copyOfRange(1,33)),BigInteger(1,raw.copyOfRange(33,65))),params))
        val server=kp.public as ECPublicKey
        val serverRaw=byteArrayOf(4)+fix(server.w.affineX)+fix(server.w.affineY)
        val shared=KeyAgreement.getInstance("ECDH").run { init(kp.private);doPhase(peer,true);generateSecret() }
        val challenge="A".repeat(43)
        val ephDigest=hex(sha(raw)); val challengeHash=sha(challenge.toByteArray(Charsets.UTF_8))
        val label="otpanda-seed-sync-seal-v1"
        val info="$label|$ephDigest|${hex(sha(serverRaw))}".toByteArray(Charsets.UTF_8)
        val prk=hmac(challengeHash,shared)
        val key=hmac(prk,info+byteArrayOf(1))
        val aad="[\"$label\",\"fixture-owner\",\"device\",0,\"sealed-entry\",1,\"SHA-1\",8,30,\"${hex(challengeHash)}\",\"$ephDigest\"]".toByteArray(Charsets.UTF_8)
        val nonce=ByteArray(12).also { SecureRandom().nextBytes(it) }
        val seed="12345678901234567890".toByteArray(Charsets.US_ASCII)
        return try {
            val sealed=Cipher.getInstance("AES/GCM/NoPadding").run { init(Cipher.ENCRYPT_MODE,SecretKeySpec(key,"AES"),GCMParameterSpec(128,nonce));updateAAD(aad);doFinal(seed) }
            mapOf("serverPublicKey" to b64(serverRaw),"nonce" to b64(nonce),"ciphertext" to b64(sealed))
        } finally { shared.fill(0);prk.fill(0);key.fill(0);seed.fill(0) }
    }
}
