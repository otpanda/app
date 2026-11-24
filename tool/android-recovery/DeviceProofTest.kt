package org.otpanda.recovery
import java.security.KeyPairGenerator
import java.security.Signature
fun main(args: Array<String>) {
    val now=1800000000000L
    val proof=DeviceProof("recover-access","owner","key",1,"A".repeat(43),"b".repeat(64),now+120000)
    val bytes=proof.message(now)
    check(String(bytes)=="[\"otpanda-device-proof-v1\",\"recover-access\",\"owner\",\"key\",1,\"${"A".repeat(43)}\",\"${"b".repeat(64)}\",1800000120000]")
    fun denies(block:()->Unit){check(runCatching(block).isFailure)}
    for(p in listOf(proof.copy(purpose="reset-all"),proof.copy(ownerId="owner\""),proof.copy(keyId=""),proof.copy(generation=-1),proof.copy(challenge="A"),proof.copy(actionDigest="B".repeat(64)),proof.copy(expiresAt=now)))denies{p.message(now)}
    check(proof.message(now-60000).contentEquals(bytes)) // Client clock behind server.
    fun seq(r: ByteArray,s: ByteArray)=byteArrayOf(0x30,(r.size+s.size+4).toByte(),2,r.size.toByte())+r+byteArrayOf(2,s.size.toByte())+s
    val padded=derToP1363(seq(byteArrayOf(0)+ByteArray(32){0x80.toByte()},ByteArray(31){1}))
    check(padded.take(32).all{it==0x80.toByte()} && padded[32].toInt()==0 && padded.drop(33).all{it.toInt()==1})
    denies{derToP1363(seq(byteArrayOf(0,1),byteArrayOf(1)))}
    val fixture=java.io.File(args.single()).readLines()
    val base64=java.util.Base64.getDecoder()
    val fixedKey=java.security.KeyFactory.getInstance("EC").generatePublic(java.security.spec.X509EncodedKeySpec(base64.decode(fixture[0])))
    check(base64.decode(fixture[1]).contentEquals(bytes))
    val fixedRaw=java.util.Base64.getUrlDecoder().decode(fixture[3])
    check(derToP1363(base64.decode(fixture[2])).contentEquals(fixedRaw))
    check(Signature.getInstance("SHA256withECDSAinP1363Format").run{initVerify(fixedKey);update(bytes);verify(fixedRaw)})
    val key=KeyPairGenerator.getInstance("EC").apply{initialize(256)}.generateKeyPair()
    repeat(128){
        val der=Signature.getInstance("SHA256withECDSA").run{initSign(key.private);update(bytes);sign()}
        val raw=derToP1363(der);check(raw.size==64)
        check(Signature.getInstance("SHA256withECDSAinP1363Format").run{initVerify(key.public);update(bytes);verify(raw)})
        denies{derToP1363(der+byteArrayOf(0))}
        denies{derToP1363(der.copyOf(der.size-1))}
    }
    for(der in listOf(byteArrayOf(),byteArrayOf(0x30,6,2,1,0,2,1,1),byteArrayOf(0x30,6,2,1,-1,2,1,1),byteArrayOf(0x30,7,2,2,0,1,2,1,1)))denies{derToP1363(der)}
    println("PASS protocol exact bytes, expiry/schema boundaries,128 actual JVM signature conversions and malformed DER rejection")
}
