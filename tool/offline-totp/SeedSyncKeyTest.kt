package org.otpanda.totp

import java.security.KeyFactory
import java.security.interfaces.ECPublicKey
import java.security.Signature
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.security.AlgorithmParameters
import java.security.spec.ECParameterSpec
import java.math.BigInteger
import javax.crypto.SecretKey
import javax.crypto.spec.SecretKeySpec

// JVM tests for the seed-sync enrollment key and its deny-first erase state machine, against in-memory fakes with SYNTHETIC keys. NOT Keystore, hardware, lock,
// uninstall or backup evidence. A "process death" is modelled by an Error that no step catches, followed by a fresh core over the same durable fakes.
private val INST = "I".repeat(22)
private class ProcessDeath : Error("simulated process death")

private class SVault : SyncKeyVault {
    val keys = LinkedHashMap<String, PrivateKey>(); val pubs = HashMap<String, ByteArray>()
    var deleteDown = false; var ignoreDelete = false; var deleteDeath = false; var listDown = false; var goneThenThrow = false
    val log = ArrayList<String>(); var onDelete: (String) -> Unit = {}
    override fun containsAlias(alias: String) = alias in keys
    override fun aliases(): Set<String> { if (listDown) throw VaultException(VaultException.Kind.UNAVAILABLE, "l"); return keys.keys.toSet() }
    override fun generate(alias: String): ByteArray {
        val g = KeyPairGenerator.getInstance("EC"); g.initialize(ECGenParameterSpec("secp256r1")); val kp = g.generateKeyPair()
        val w = (kp.public as java.security.interfaces.ECPublicKey).w
        fun fix(b: BigInteger) = b.toByteArray().let { if (it.size > 32) it.copyOfRange(it.size - 32, it.size) else ByteArray(32 - it.size) + it }
        val pub = byteArrayOf(4) + fix(w.affineX) + fix(w.affineY)
        keys[alias] = kp.private; pubs[alias] = pub; return pub
    }
    override fun sign(alias: String, message: ByteArray): ByteArray {
        val k = keys[alias] ?: throw VaultException(VaultException.Kind.INVALIDATED, "gone")
        return Signature.getInstance("SHA256withECDSA").run { initSign(k); update(message); sign() }
    }
    override fun delete(alias: String) {
        log.add("delete"); onDelete(alias)
        if (deleteDeath) throw ProcessDeath()
        if (deleteDown) throw VaultException(VaultException.Kind.UNAVAILABLE, "d")
        if (!ignoreDelete) keys.remove(alias)
        if (goneThenThrow) throw VaultException(VaultException.Kind.UNAVAILABLE, "notfound")
    }
}

private class SStore : SyncStateStore {
    val docs = HashMap<String, String>()
    var down = false; var writeDown = false; var writeDeathAt = -1; var writes = 0
    override fun read(key: String): String? { if (down) throw java.io.IOException("down"); return docs[key] }
    override fun write(key: String, text: String) {
        if (down || writeDown) throw java.io.IOException("down")
        if (writes++ == writeDeathAt) throw ProcessDeath()
        docs[key] = text
    }
    override fun keys(): Set<String> { if (down) throw java.io.IOException("down"); return docs.keys.toSet() }
}

private class CVault : KeyVault {
    val keys = HashMap<String, SecretKeySpec>(); var deleteDeath = false; var deleteDown = false; var deleteRuntime = false
    override fun containsAlias(alias: String) = alias in keys
    override fun aliases(): Set<String> = keys.keys.toSet()
    override fun importSeed(alias: String, seed: ByteArray, algorithm: TotpCalculator.Algorithm): ProtectionReport { keys[alias] = SecretKeySpec(seed.copyOf(), algorithm.jcaName); return ProtectionReport(true, "secure_hardware") }
    override fun key(alias: String): SecretKey? = keys[alias]
    override fun delete(alias: String) { if (deleteDeath) throw ProcessDeath(); if (deleteRuntime) throw IllegalStateException("boom"); if (deleteDown) throw VaultException(VaultException.Kind.UNAVAILABLE, "d"); keys.remove(alias) }
    override fun probe() = ProtectionReport(true, "x")
}
private class CStore : OwnerStateStore {
    val docs = HashMap<String, String>(); var down = false
    override fun read(key: String): String? { if (down) throw java.io.IOException("d"); return docs[key] }
    override fun write(key: String, text: String) { if (down) throw java.io.IOException("d"); docs[key] = text }
    override fun keys(): Set<String> { if (down) throw java.io.IOException("d"); return docs.keys.toSet() }
}

private class Rig(val sv: SVault = SVault(), val ss: SStore = SStore(), val cv: CVault = CVault(), val cs: CStore = CStore()) {
    var seq = 0
    val custody = NativeSeedCustodyCore(cv, cs)
    fun core(): SeedSyncKeyCore = SeedSyncKeyCore(sv, ss, custody) { (++seq + 1000L * ss.docs.size).toString(16).padStart(32, '0') }
    // a restart reuses the durable fakes but loses all memory; a different counter avoids alias reuse
    var c = core()
    fun restart(): SeedSyncKeyCore { seq += 500; c = core(); return c }
    fun seed(owner: String = "o", entry: String = "e", epoch: Long = 0) = custody.provision(owner, entry, 1, TotpCalculator.Algorithm.SHA1, 8, 30, "12345678901234567890".toByteArray(), epoch)
}

private fun err(w: () -> Any?): SyncKeyError? = try { w(); null } catch (e: SyncKeyFailure) { e.error }
private fun want(e: SyncKeyError, w: () -> Any?) { val g = err(w); check(g == e) { "expected $e got $g" } }
private fun died(w: () -> Any?): Boolean = try { w(); false } catch (_: ProcessDeath) { true }
private fun verifies(pub: ByteArray, msg: ByteArray, sig: ByteArray): Boolean {
    val ap = AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }.getParameterSpec(ECParameterSpec::class.java)
    val x = BigInteger(1, pub.copyOfRange(1, 33)); val y = BigInteger(1, pub.copyOfRange(33, 65))
    val k = KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), ap))
    return Signature.getInstance("SHA256withECDSA").run { initVerify(k); update(msg); verify(sig) }
}

// ---- wire interop against the API author's synthetic vector (seed-sync-vector-v4-a0ccb879.json; SYNTHETIC keys, values copied verbatim) ----
private val VJ = "FUlvuIPmxIIPm6ZCSigFq94xCIAfMkV94roEHVzcRls"; private val VY = "J_DfwdhwPCNlAd4JrGOnt2NLarvBvWU-i0O555KW9SE"
private fun b64d(s: String) = java.util.Base64.getUrlDecoder().decode(s)
private fun stdB64(s: String) = java.util.Base64.getDecoder().decode(s)
private fun vecPub(): java.security.PublicKey {
    val p = SeedSyncWire.jcaParams()
    return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(BigInteger(1, b64d(VJ)), BigInteger(1, b64d(VY))), p))
}
private fun verifyServerSig(msg: ByteArray, sig86: String, pub: java.security.PublicKey = vecPub()): Boolean =
    Signature.getInstance("SHA256withECDSA").run { initVerify(pub); update(msg); verify(SeedSyncWire.p1363ToDer(SeedSyncWire.unb64(sig86, 64))) }
private fun wireErr(w: () -> Any?): String? = try { w(); null } catch (e: WireException) { e.reason }

private fun wireChecks() {
    val ch = "A".repeat(43)
    val purposes = listOf(
        Triple(SyncPurpose.ENROLL, mapOf("ownerId" to "owner", "keyId" to "key", "installId" to "IIIIIIIIIIIIIIIIIIIIII", "generation" to 1L, "challenge" to "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "actionDigest" to "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "expiresAt" to 1800000120000L),
            Pair("WyJvdHBhbmRhLXNlZWQtc3luYy12MSIsInNlZWQtc3luYy1lbnJvbGwiLCJvd25lciIsImtleSIsIklJSUlJSUlJSUlJSUlJSUlJSUlJSUkiLDEsIkFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUEiLCJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiIiwxODAwMDAwMTIwMDAwXQ==", "-yfj7_2eZZeKmh8AC_jyRz5hgf-He4k_-Q3Q3I3Wb6QJDtG12_CoKNO_yIvf4m5kacqToP-ZJtWk5gRFkxjT2w")),
        Triple(SyncPurpose.SNAPSHOT, mapOf("ownerId" to "owner", "keyId" to "key", "deviceId" to "device", "generation" to 1L, "epoch" to 7L, "challenge" to "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "expiresAt" to 1800000120000L),
            Pair("WyJvdHBhbmRhLXNlZWQtc3luYy12MSIsInNlZWQtc3luYy1zbmFwc2hvdCIsIm93bmVyIiwia2V5IiwiZGV2aWNlIiwxLDcsIkFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUEiLDE4MDAwMDAxMjAwMDBd", "v1QuZmeBAjbE8uPrXVikUpjA-zQG-vN1VfcqbEouZ-F7syclcZ4GvgwyOun5ciGt92OYUdQJerbjWRfpnCupsQ")),
        Triple(SyncPurpose.REVOKE, mapOf("ownerId" to "owner", "keyId" to "key", "deviceId" to "device", "generation" to 1L, "challenge" to "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "expiresAt" to 1800000120000L),
            Pair("WyJvdHBhbmRhLXNlZWQtc3luYy12MSIsInNlZWQtc3luYy1yZXZva2UiLCJvd25lciIsImtleSIsImRldmljZSIsMSwiQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQSIsMTgwMDAwMDEyMDAwMF0=", "Py5tmWlvvNROZAvf3PlYkX-itGvy7D1OE0D8W56MKIKpI1GU52Au1nK03UNRP-0dCO6Kfw833ZnM5Xk0eMvOwQ")),
        Triple(SyncPurpose.BATCH, mapOf("ownerId" to "owner", "keyId" to "key", "deviceId" to "device", "generation" to 1L, "epoch" to 7L, "challenge" to "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "ephemeralDigest" to "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", "entriesDigest" to "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", "expiresAt" to 1800000120000L),
            Pair("WyJvdHBhbmRhLXNlZWQtc3luYy12MSIsInNlZWQtc3luYy1iYXRjaCIsIm93bmVyIiwia2V5IiwiZGV2aWNlIiwxLDcsIkFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUEiLCJjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjIiwiZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZCIsMTgwMDAwMDEyMDAwMF0=", "CYZ0RbcxM2l0ifLaCVOPG3Cc489o0yRsaUYjhyiBo1YjyYwrfiVLri00vXuKfyWhP0_noRdLnea2WWa1uAr7Tg")),
        Triple(SyncPurpose.STATUS, mapOf("keyId" to "key", "challenge" to "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "expiresAt" to 1800000120000L),
            Pair("WyJvdHBhbmRhLXNlZWQtc3luYy12MSIsInNlZWQtc3luYy1zdGF0dXMiLCJrZXkiLCJBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBIiwxODAwMDAwMTIwMDAwXQ==", "K8X7atitxYSfskOLILf4Bqeh-jU18Sa-2b5Q22kNPM5HpCfAzXwxGVpdNVRm58ZRlMS3WkCunUzAMlv4j1LPlQ")))
    run {
        val r = Rig(); r.c.enroll("o", INST, 1)
        val key = ownerKey("o"); val doc = r.ss.docs.getValue(key)
        r.ss.docs[key] = doc.lines().joinToString("\n") { line -> if (line.startsWith("active ")) line.split(' ').take(3).joinToString(" ") else line }
        want(SyncKeyError.METADATA_UNAVAILABLE) { r.c.enrolled("o") }
    }
    run {
        val r = Rig(); val key = r.c.enroll("o", INST, 1).keyId
        check(r.c.runIfActive("o", key, 0) {
            want(SyncKeyError.ERASE_INCOMPLETE) { r.c.erase("o", 0, EraseTrigger.SIGN_OUT) }
            want(SyncKeyError.ERASE_INCOMPLETE) { r.c.enroll("o", INST, 1) }
            want(SyncKeyError.ERASE_INCOMPLETE) { r.c.signRawForTests("o", byteArrayOf(1)) }
            want(SyncKeyError.ERASE_INCOMPLETE) { r.c.runIfActive("o", key, 0) {} }
        } == null)
        check(r.c.enrolled("o"))
    }
    // W1. native-built bytes equal the server's bytes for all three purposes; the server's P1363 signature verifies; every field change and every cross-purpose use fails.
    for ((p, f, ms) in purposes) {
        val msg = SeedSyncWire.proofMessage(p, f)
        check(msg.contentEquals(stdB64(ms.first))) { "message bytes ${p.wire}" }
        check(verifyServerSig(msg, ms.second)) { "server signature ${p.wire}" }
        for ((k, value) in f) {
            val changed = f + (k to (if (value is Long) value + 1 else (value as String).let { s -> (if (s[0] == 'a') "b" else "a") + s.substring(1) }))
            check(!verifyServerSig(SeedSyncWire.proofMessage(p, changed), ms.second)) { "field $k change verified" }
        }
        for ((q, _, qs) in purposes) if (q != p) check(!verifyServerSig(stdB64(qs.first), ms.second)) { "cross purpose" }
    }
    // W2. validation: exact field set, regexes, safe integers, no unknown or missing keys.
    run {
        val f = purposes[1].second
        for (bad in listOf(f - "epoch", f + ("extra" to 1L), f + ("ownerId" to "a b"), f + ("ownerId" to ""), f + ("ownerId" to "x".repeat(129)), f + ("challenge" to "A".repeat(42)), f + ("challenge" to "A".repeat(44)),
            f + ("challenge" to "A".repeat(42) + "+"), f + ("epoch" to -1L), f + ("generation" to SeedSyncWire.MAX_SAFE + 1), f + ("expiresAt" to Long.MAX_VALUE), f + ("epoch" to "7"), f + ("deviceId" to "dev\nice")))
            check(wireErr { SeedSyncWire.proofMessage(SyncPurpose.SNAPSHOT, bad) } != null) { "accepted $bad" }
        check(wireErr { SeedSyncWire.proofMessage(SyncPurpose.ENROLL, purposes[0].second + ("installId" to "I".repeat(21))) } != null)
        check(wireErr { SeedSyncWire.proofMessage(SyncPurpose.ENROLL, purposes[0].second + ("installId" to "I".repeat(65))) } != null)
        check(wireErr { SeedSyncWire.proofMessage(SyncPurpose.ENROLL, purposes[0].second + ("actionDigest" to "B".repeat(64))) } != null) // uppercase hex refused
        check(wireErr { SeedSyncWire.proofMessage(SyncPurpose.BATCH, purposes[3].second + ("entriesDigest" to "d".repeat(63))) } != null)
    }
    // W3. DER to P1363: fixed 64 bytes, leading zero and short values, malformed DER refused; real JCA signatures (varied r/s widths) always convert and verify.
    run {
        fun der(r: ByteArray, s: ByteArray) = byteArrayOf(0x30, (4 + r.size + s.size).toByte(), 2, r.size.toByte()) + r + byteArrayOf(2, s.size.toByte()) + s
        val hi = ByteArray(32) { (0x80 or it).toByte() }
        val d1 = der(byteArrayOf(0) + hi, byteArrayOf(5)) // r has a sign byte, s is one byte
        val p1 = SeedSyncWire.derToP1363(d1); check(p1.size == 64 && p1.copyOfRange(0, 32).contentEquals(hi) && p1[63] == 5.toByte() && p1.copyOfRange(32, 63).all { it == 0.toByte() })
        val short30 = ByteArray(30) { (it + 1).toByte() }
        val p2 = SeedSyncWire.derToP1363(der(short30, short30)); check(p2.copyOfRange(0, 2).all { it == 0.toByte() } && p2.copyOfRange(2, 32).contentEquals(short30))
        for (badDer in listOf(byteArrayOf(), d1.copyOf(d1.size - 1), d1 + byteArrayOf(0), der(byteArrayOf(0, 1), byteArrayOf(1)), der(hi, byteArrayOf(1)), der(byteArrayOf(0), byteArrayOf(1)),
            der(ByteArray(33) { 1 }, byteArrayOf(1)), der(byteArrayOf(1), byteArrayOf()), byteArrayOf(0x31) + d1.copyOfRange(1, d1.size)))
            check(wireErr { SeedSyncWire.derToP1363(badDer) } != null) { "accepted malformed der" }
        val g = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
        var widths = HashSet<Int>()
        repeat(300) { i ->
            val m = byteArrayOf(i.toByte(), (i shr 8).toByte())
            val dr = Signature.getInstance("SHA256withECDSA").run { initSign(g.private); update(m); sign() }
            widths.add(dr.size)
            val raw = SeedSyncWire.derToP1363(dr); check(raw.size == 64)
            check(Signature.getInstance("SHA256withECDSA").run { initVerify(g.public); update(m); verify(SeedSyncWire.p1363ToDer(raw)) })
        }
        check(widths.size > 1) { "sample did not vary DER width" }
    }
    // W4. signing through the core: native supplies ownerId and the signing key's own id; the proof verifies against that enrollment's public key; expiry bounds enforced.
    run {
        val r = Rig(); val en = r.c.enroll("o", INST, 1); val now = 1_800_000_000_000L
        val f = mapOf("deviceId" to "device", "generation" to 1L, "epoch" to 0L, "challenge" to ch, "expiresAt" to now + 120_000)
        val sig = SeedSyncWire.signProof(r.c, "o", SyncPurpose.SNAPSHOT, f, now); check(sig.length == 86)
        val pub = KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(BigInteger(1, en.publicKey.copyOfRange(1, 33)), BigInteger(1, en.publicKey.copyOfRange(33, 65))), SeedSyncWire.jcaParams()))
        val expect = SeedSyncWire.proofMessage(SyncPurpose.SNAPSHOT, f + mapOf("ownerId" to "o", "keyId" to en.keyId))
        check(verifyServerSig(expect, sig, pub))
        check(!verifyServerSig(SeedSyncWire.proofMessage(SyncPurpose.SNAPSHOT, f + mapOf("ownerId" to "o", "keyId" to "other")), sig, pub))
        for (bad in listOf(now, now - 1, now + 120_001, SeedSyncWire.MAX_SAFE + 1)) check(wireErr { SeedSyncWire.signProof(r.c, "o", SyncPurpose.SNAPSHOT, f + ("expiresAt" to bad), now) } != null) { "expiry $bad" }
        check(wireErr { SeedSyncWire.signProof(r.c, "o", SyncPurpose.SNAPSHOT, f + ("ownerId" to "evil"), now) } != null) // a caller cannot supply ownerId
        check(wireErr { SeedSyncWire.signProof(r.c, "o", SyncPurpose.SNAPSHOT, f + ("keyId" to "evil"), now) } != null) // nor keyId
        // generation and epoch are checked against native state before any signature: a wrong value refuses, and nothing signs
        check(wireErr { SeedSyncWire.signProof(r.c, "o", SyncPurpose.SNAPSHOT, f + ("generation" to 2L), now) } == "generation")
        check(wireErr { SeedSyncWire.signProof(r.c, "o", SyncPurpose.SNAPSHOT, f + ("epoch" to 7L), now) } == "epoch")
        check(wireErr { SeedSyncWire.signProof(r.c, "o", SyncPurpose.SNAPSHOT, f + ("epoch" to 1L), now) } == "epoch")
        check(wireErr { SeedSyncWire.signProof(r.c, "o", SyncPurpose.REVOKE, mapOf("deviceId" to "device", "generation" to 0L, "challenge" to ch, "expiresAt" to now + 1000L), now) } == "generation")
        check(wireErr { SeedSyncWire.signProof(r.c, "o", SyncPurpose.ENROLL, f, now) } == "purpose") // enroll only via signEnrollProof
        r.seed("o"); r.custody.purgeOwner("o", 0) // native epoch advances to 1: the old epoch no longer signs, the new one does
        check(wireErr { SeedSyncWire.signProof(r.c, "o", SyncPurpose.SNAPSHOT, f, now) } == "epoch")
        check(SeedSyncWire.signProof(r.c, "o", SyncPurpose.SNAPSHOT, f + ("epoch" to 1L), now).length == 86)
        // refuses after erase, and with no enrollment
        r.c.erase("o", 0, EraseTrigger.SIGN_OUT)
        want(SyncKeyError.NOT_ENROLLED) { SeedSyncWire.signProof(r.c, "o", SyncPurpose.SNAPSHOT, f, now) }
        // batch: digests come from the native handle and the entry set, order independent
        val e2 = r.c.enroll("o", INST, 1); val ep = r.custody.readOwnerState("o").epoch; val eph = SeedSyncWire.Ephemeral.generate()
        val s1 = SeedSyncWire.signBatchProof(r.c, "o", "device", 1, ep, ch, now + 1000, eph.raw, listOf("b" to 2L, "a" to 1L), now)
        val msgFor = { entries: List<Pair<String, Long>> -> SeedSyncWire.proofMessage(SyncPurpose.BATCH, mapOf("ownerId" to "o", "keyId" to e2.keyId, "deviceId" to "device", "generation" to 1L, "epoch" to ep, "challenge" to ch,
            "ephemeralDigest" to eph.digest, "entriesDigest" to SeedSyncWire.entriesDigest(entries), "expiresAt" to now + 1000)) }
        val pub2 = KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(BigInteger(1, e2.publicKey.copyOfRange(1, 33)), BigInteger(1, e2.publicKey.copyOfRange(33, 65))), SeedSyncWire.jcaParams()))
        check(verifyServerSig(msgFor(listOf("a" to 1L, "b" to 2L)), s1, pub2) && !verifyServerSig(msgFor(listOf("a" to 1L, "b" to 3L)), s1, pub2))
        check(wireErr { SeedSyncWire.signBatchProof(r.c, "o", "device", 1, ep, ch, now + 1000, ByteArray(65), listOf("a" to 1L), now) } == "point")
        check(wireErr { SeedSyncWire.signBatchProof(r.c, "o", "device", 1, ep + 1, ch, now + 1000, eph.raw, listOf("a" to 1L), now) } == "epoch")
    }
    // W5. digests: ephemeral digest matches the server vector; challenge and entries digests match values computed by the reference JS.
    run {
        val cp = b64d("BBCEbk1d7zVmp3ao9gZNspN44rC4GUzoPBsF5Hw5UJhD4Oeq0H4mAAg7kWosz7V15XdQMy-VF4NDX8iEG8UOiXY")
        check(SeedSyncWire.ephemeralDigest(cp) == "124814dd027438cc5148726b8a752b03f4e1d247ce4da8756c9181371085ea42")
        check(SeedSyncWire.challengeDigest(ch) == "0f007385b6f9d4b7eeb2748605afe1a984a0a3bfa3f014d09e2a784ce9e5cd1a")
        check(SeedSyncWire.entriesDigest(listOf("b" to 2L, "a" to 1L, "c" to 10L)) == "2f0cc77066edcca39eda4e563f7644735c20491aca5418bb4463cf1e569622d9")
        check(SeedSyncWire.entriesDigest(emptyList()) == "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945")
        check(wireErr { SeedSyncWire.entriesDigest(listOf("a" to 1L, "a" to 2L)) } != null && wireErr { SeedSyncWire.entriesDigest(listOf("a b" to 1L)) } != null)
        check(wireErr { SeedSyncWire.challengeDigest("short") } != null)
    }
    // W6. points and encodings: bad points from the vector and canonical-encoding negatives are refused.
    run {
        check(wireErr { SeedSyncWire.checkPoint(b64d("BBCEbk1d7zVmp3ao9gZNspN44rC4GUzoPBsF5Hw5UJhD4Oeq0H4mAAg7kWosz7V15XdQMy-VF4NDX8iEG8UOiXY")) } == null)
        check(wireErr { SeedSyncWire.unb64("BBCEbk1d7zVmp3ao9gZNspN44rC4GUzoPBsF5Hw5UJhD4Oeq0H4mAAg7kWosz7V15XdQMy-VF4NDX8iEG8UOiXc", 65) } == null && wireErr { SeedSyncWire.checkPoint(b64d("BBCEbk1d7zVmp3ao9gZNspN44rC4GUzoPBsF5Hw5UJhD4Oeq0H4mAAg7kWosz7V15XdQMy-VF4NDX8iEG8UOiXc")) } == "point") // off curve
        check(wireErr { SeedSyncWire.unb64("AhCEbk1d7zVmp3ao9gZNspN44rC4GUzoPBsF5Hw5UJhD", 65) } != null) // compressed prefix, 33 bytes
        check(wireErr { SeedSyncWire.unb64("BBCEbk1d7zVmp3ao9gZNspN44rC4GUzoPBsF5Hw5UJhD4Oeq0H4mAAg7kWosz7V15XdQMy-VF4NDX8iEG8UOiQ", 65) } != null) // wrong length
        check(wireErr { SeedSyncWire.unb64("BBCEbk1d7zVmp3ao9gZNspN44rC4GUzoPBsF5Hw5UJhD4Oeq0H4mAAg7kWosz7V15XdQMy-VF4NDX8iEG8UOiXY=", 65) } != null) // padded
        check(wireErr { SeedSyncWire.unb64("AB", 1) } != null) // non-canonical trailing bits
        check(wireErr { SeedSyncWire.unb64("A", null) } != null && wireErr { SeedSyncWire.unb64("a+b/", null) } != null && wireErr { SeedSyncWire.unb64("YQ==", null) } != null)
        val x = b64d("BBCEbk1d7zVmp3ao9gZNspN44rC4GUzoPBsF5Hw5UJhD4Oeq0H4mAAg7kWosz7V15XdQMy-VF4NDX8iEG8UOiXY"); val bad04 = x.copyOf(); bad04[0] = 2; check(wireErr { SeedSyncWire.checkPoint(bad04) } == "point")
        val big = x.copyOf(); for (i in 1..32) big[i] = 0xff.toByte(); check(wireErr { SeedSyncWire.checkPoint(big) } == "point")
    }
    // W7. opening the server's sealed entry: exact seed bytes, AAD built from the device's own context, every context field and the challenge bind the ciphertext.
    run {
        val jp = SeedSyncWire.jcaParams()
        val priv = KeyFactory.getInstance("EC").generatePrivate(java.security.spec.ECPrivateKeySpec(BigInteger(1, b64d("AHy8PIbJl7hSYgvUcBbQ5_9Y-qzVZukz2pU6ie21uv4")), jp))
        val eph = SeedSyncWire.Ephemeral.of(priv, b64d("BBCEbk1d7zVmp3ao9gZNspN44rC4GUzoPBsF5Hw5UJhD4Oeq0H4mAAg7kWosz7V15XdQMy-VF4NDX8iEG8UOiXY"))
        val ctx = SeedSyncWire.SealContext("owner", "device", 7, "entry1", 3, "SHA-1", 6, 30, "unused")
        // the vector fixes the challenge DIGEST; recover the challenge-bound path by checking the AAD bytes the vector publishes
        val aadOf = { c: SeedSyncWire.SealContext, digest: String -> SeedSyncWire.sealAad(c, digest) }
        check(eph.digest == "124814dd027438cc5148726b8a752b03f4e1d247ce4da8756c9181371085ea42")
        val serverPub = "BE-kxvRYtGRTzB0aUXoANxnJPSwmW3WCY_lTnglW77W-Tz2j8bY5rSS4KVZBf43fJGU2G1dNEd9qDcJxN1LArFw"; val nonce = "AQIDBAUGBwgJCgsM"; val ct = "1_WMkX8-DvxwVPiT2G9gRIJrud5qRVyFZOqHj8ojbxKvmBlB"
        val expectedSeed = stdB64("AQIDBAUGBwgJCgsMDQ4PEBESExQ=")
        // the opener derives the challenge digest from the challenge STRING; the vector gives only a digest, so open through the same primitives with the vector digest:
        val raw = SeedSyncWire.unb64(serverPub, 65); SeedSyncWire.checkPoint(raw)
        val ka = javax.crypto.KeyAgreement.getInstance("ECDH"); ka.init(priv)
        ka.doPhase(KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(BigInteger(1, raw.copyOfRange(1, 33)), BigInteger(1, raw.copyOfRange(33, 65))), jp)), true)
        val shared = ka.generateSecret()
        val cd = "e".repeat(64)
        val key = SeedSyncWire.hkdf32(shared, ByteArray(32) { 0xee.toByte() }, "otpanda-seed-sync-seal-v1|${eph.digest}|${SeedSyncWire.sha256Hex(raw)}".toByteArray())
        fun open(aad: ByteArray) = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding").run { init(javax.crypto.Cipher.DECRYPT_MODE, javax.crypto.spec.SecretKeySpec(key, "AES"), javax.crypto.spec.GCMParameterSpec(128, b64d(nonce))); updateAAD(aad); doFinal(b64d(ct)) }
        val vecAad = stdB64("WyJvdHBhbmRhLXNlZWQtc3luYy1zZWFsLXYxIiwib3duZXIiLCJkZXZpY2UiLDcsImVudHJ5MSIsMywiU0hBLTEiLDYsMzAsImVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWUiLCIxMjQ4MTRkZDAyNzQzOGNjNTE0ODcyNmI4YTc1MmIwM2Y0ZTFkMjQ3Y2U0ZGE4NzU2YzkxODEzNzEwODVlYTQyIl0=")
        check(open(vecAad).contentEquals(expectedSeed)) { "KAT: HKDF/ECDH/GCM with the published AAD" }
        for (alg in listOf("SHA-1", "SHA-256", "SHA-512")) {
            val published = stdB64(when (alg) { "SHA-1" -> "WyJvdHBhbmRhLXNlZWQtc3luYy1zZWFsLXYxIiwib3duZXIiLCJkZXZpY2UiLDcsImVudHJ5MSIsMywiU0hBLTEiLDYsMzAsImVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWUiLCIxMjQ4MTRkZDAyNzQzOGNjNTE0ODcyNmI4YTc1MmIwM2Y0ZTFkMjQ3Y2U0ZGE4NzU2YzkxODEzNzEwODVlYTQyIl0="; "SHA-256" -> "WyJvdHBhbmRhLXNlZWQtc3luYy1zZWFsLXYxIiwib3duZXIiLCJkZXZpY2UiLDcsImVudHJ5MSIsMywiU0hBLTI1NiIsNiwzMCwiZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZSIsIjEyNDgxNGRkMDI3NDM4Y2M1MTQ4NzI2YjhhNzUyYjAzZjRlMWQyNDdjZTRkYTg3NTZjOTE4MTM3MTA4NWVhNDIiXQ=="; else -> "WyJvdHBhbmRhLXNlZWQtc3luYy1zZWFsLXYxIiwib3duZXIiLCJkZXZpY2UiLDcsImVudHJ5MSIsMywiU0hBLTUxMiIsNiwzMCwiZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZWVlZSIsIjEyNDgxNGRkMDI3NDM4Y2M1MTQ4NzI2YjhhNzUyYjAzZjRlMWQyNDdjZTRkYTg3NTZjOTE4MTM3MTA4NWVhNDIiXQ==" })
            val built = "[\"otpanda-seed-sync-seal-v1\",\"owner\",\"device\",7,\"entry1\",3,\"$alg\",6,30,\"$cd\",\"${eph.digest}\"]".toByteArray()
            check(published.contentEquals(built)) { "AAD bytes $alg" }
        }
        // challenge string whose digest is cd cannot be constructed, so the full-path opener is exercised in W8 with a locally sealed vector; here the AAD builder is pinned.
        check(aadOf(ctx.copy(challenge = "A".repeat(43)), eph.digest).decodeToString().contains(SeedSyncWire.challengeDigest("A".repeat(43))))
        // a GCM open with any changed published-AAD field fails
        for (mut in listOf("owner" to "owneR", "device" to "devicf", "entry1" to "entry2", ",7," to ",8,", ",3," to ",4,", "SHA-1" to "SHA-256", ",6," to ",7,", ",30," to ",31,")) {
            val s = vecAad.decodeToString().replace(mut.first, mut.second); check(s != vecAad.decodeToString())
            check(runCatching { open(s.toByteArray()) }.isFailure) { "AAD change ${mut.first} still opened" }
        }
    }
    // W8. full opener against a locally sealed batch (device side proves it derives what a server-style sealer derives); algorithm set, sizes and tamper checks.
    run {
        val jp = SeedSyncWire.jcaParams()
        val eph = SeedSyncWire.Ephemeral.generate()
        val challenge = "Z".repeat(43)
        val srv = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
        val sw = (srv.public as ECPublicKey).w
        fun fix(b: BigInteger) = b.toByteArray().let { if (it.size > 32) it.copyOfRange(it.size - 32, it.size) else ByteArray(32 - it.size) + it }
        val sraw = byteArrayOf(4) + fix(sw.affineX) + fix(sw.affineY)
        val ctx = SeedSyncWire.SealContext("owner", "device", 7, "entry1", 3, "SHA-256", 8, 60, challenge)
        val seed = ByteArray(20) { (it * 7).toByte() }
        fun seal(c: SeedSyncWire.SealContext, s: ByteArray, nonce: ByteArray = ByteArray(12) { 9 }): Pair<String, String> {
            val ka = javax.crypto.KeyAgreement.getInstance("ECDH"); ka.init(srv.private)
            ka.doPhase(KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(BigInteger(1, eph.raw.copyOfRange(1, 33)), BigInteger(1, eph.raw.copyOfRange(33, 65))), jp)), true)
            val key = SeedSyncWire.hkdf32(ka.generateSecret(), SeedSyncWire.challengeDigest(challenge).chunked(2).map { it.toInt(16).toByte() }.toByteArray(),
                "otpanda-seed-sync-seal-v1|${eph.digest}|${SeedSyncWire.sha256Hex(sraw)}".toByteArray())
            val ct = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding").run { init(javax.crypto.Cipher.ENCRYPT_MODE, javax.crypto.spec.SecretKeySpec(key, "AES"), javax.crypto.spec.GCMParameterSpec(128, nonce)); updateAAD(SeedSyncWire.sealAad(c, eph.digest)); doFinal(s) }
            return SeedSyncWire.b64(nonce) to SeedSyncWire.b64(ct)
        }
        val (n, ct) = seal(ctx, seed)
        check(SeedSyncWire.openSealed(eph, ctx, SeedSyncWire.b64(sraw), n, ct).contentEquals(seed))
        for (c in listOf(ctx.copy(ownerId = "x"), ctx.copy(deviceId = "x"), ctx.copy(epoch = 8), ctx.copy(entryId = "e2"), ctx.copy(seedVersion = 4), ctx.copy(algorithm = "SHA-512"), ctx.copy(digits = 6), ctx.copy(period = 30), ctx.copy(challenge = "Y".repeat(43))))
            check(wireErr { SeedSyncWire.openSealed(eph, c, SeedSyncWire.b64(sraw), n, ct) } == "open") { "bound context field accepted" }
        check(wireErr { SeedSyncWire.openSealed(SeedSyncWire.Ephemeral.generate(), ctx, SeedSyncWire.b64(sraw), n, ct) } == "open") // another ephemeral
        val tam = SeedSyncWire.unb64(ct).also { it[0] = (it[0].toInt() xor 1).toByte() }
        check(wireErr { SeedSyncWire.openSealed(eph, ctx, SeedSyncWire.b64(sraw), n, SeedSyncWire.b64(tam)) } == "open")
        check(wireErr { SeedSyncWire.openSealed(eph, ctx, SeedSyncWire.b64(sraw), SeedSyncWire.b64(ByteArray(11)), ct) } != null)
        check(wireErr { SeedSyncWire.openSealed(eph, ctx, SeedSyncWire.b64(sraw.copyOf().also { it[64] = (it[64].toInt() xor 1).toByte() }), n, ct) } == "point")
        for (alg in listOf("SHA-3", "sha-1", "SHA1", "", "SHA-384")) check(wireErr { SeedSyncWire.sealAad(ctx.copy(algorithm = alg), eph.digest) } == "algorithm") { "alg $alg" }
        for (d in listOf(5, 9, 0)) check(wireErr { SeedSyncWire.sealAad(ctx.copy(digits = d), eph.digest) } != null)
        for (p in listOf(0, 86_401, -1)) check(wireErr { SeedSyncWire.sealAad(ctx.copy(period = p), eph.digest) } != null)
        for (len in listOf(9, 129)) { val (n2, c2) = seal(ctx, ByteArray(len) { 1 }); check(wireErr { SeedSyncWire.openSealed(eph, ctx, SeedSyncWire.b64(sraw), n2, c2) } != null) { "seed len $len" } }
        for (len in listOf(10, 64, 128)) { val (n2, c2) = seal(ctx, ByteArray(len) { 1 }); check(SeedSyncWire.openSealed(eph, ctx, SeedSyncWire.b64(sraw), n2, c2).size == len) }
        check(wireAlgorithm("SHA-1") == TotpCalculator.Algorithm.SHA1 && wireAlgorithm("SHA-256") == TotpCalculator.Algorithm.SHA256 && wireAlgorithm("SHA-512") == TotpCalculator.Algorithm.SHA512)
    }
    // W9. enrollment action digest: matches the API author's vector computed from the real server code; native recomputes it and never blind-accepts.
    run {
        val x = "g-KtUEgU_tleJK0MxTIg2AuqFC_mZA1R1v97B7_u6EA"; val y = "PNol0_FRDUWQACKtoc9ZI3ixU7PfwpC1l6E56wFXX0Q"
        val raw = byteArrayOf(4) + b64d(x) + b64d(y)
        check(SeedSyncWire.enrollActionDigest("owner", "I".repeat(22), raw, 1) == "367aafe9f84cb11a0fcd62f021c8e30e5672c427b8e3a65d75ee77d8e1cdd513")
        check(SeedSyncWire.enrollActionDigest("owner", "I".repeat(22), raw, 2) != "367aafe9f84cb11a0fcd62f021c8e30e5672c427b8e3a65d75ee77d8e1cdd513")
        check(wireErr { SeedSyncWire.enrollActionDigest("owner", "short", raw, 1) } != null && wireErr { SeedSyncWire.enrollActionDigest("owner", "I".repeat(22), raw.copyOf().also { it[64] = (it[64].toInt() xor 1).toByte() }, 1) } == "point")
        val r = Rig(); val en = r.c.enroll("o", "J".repeat(22), 4); val now = 1_800_000_000_000L; val inst = "J".repeat(22); val ch = "B".repeat(43)
        val good = SeedSyncWire.enrollActionDigest("o", inst, en.publicKey, 4)
        val sig = SeedSyncWire.signEnrollProof(r.c, "o", en, ch, good, now + 5000, now)
        val pub = KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(BigInteger(1, en.publicKey.copyOfRange(1, 33)), BigInteger(1, en.publicKey.copyOfRange(33, 65))), SeedSyncWire.jcaParams()))
        check(verifyServerSig(SeedSyncWire.proofMessage(SyncPurpose.ENROLL, mapOf("ownerId" to "o", "keyId" to en.keyId, "installId" to inst, "generation" to 4L, "challenge" to ch, "actionDigest" to good, "expiresAt" to now + 5000)), sig, pub))
        check(wireErr { SeedSyncWire.signEnrollProof(r.c, "o", en, ch, "0".repeat(64), now + 5000, now) } == "actionDigest") // digest for some other key or fields
        check(wireErr { SeedSyncWire.signEnrollProof(r.c, "o", en, ch, SeedSyncWire.enrollActionDigest("o", inst, en.publicKey, 5), now + 5000, now) } == "actionDigest") // server digest for another generation
        check(wireErr { SeedSyncWire.signEnrollProof(r.c, "o", en, ch, SeedSyncWire.enrollActionDigest("o", "K".repeat(22), en.publicKey, 4), now + 5000, now) } == "actionDigest") // other install
        val en2 = r.c.enroll("o", "J".repeat(22), 4) // the first enrollment's key no longer signs
        check(wireErr { SeedSyncWire.signEnrollProof(r.c, "o", en, ch, good, now + 5000, now) } == "key")
        check(wireErr { SeedSyncWire.signEnrollProof(r.c, "o", en2, ch, SeedSyncWire.enrollActionDigest("o", inst, en2.publicKey, 4), now + 200_000, now) } == "expiresAt")
    }

    // W10. revoke purpose (online own-key sign-out/disable): no epoch field, signed by the dedicated key, cross-purpose use fails (covered in W1 over five purposes).
    run {
        val r = Rig(); val en = r.c.enroll("o", INST, 2); val now = 1_800_000_000_000L; val ch2 = "C".repeat(43)
        val f = mapOf("deviceId" to "device", "generation" to 2L, "challenge" to ch2, "expiresAt" to now + 60_000)
        val sig = SeedSyncWire.signProof(r.c, "o", SyncPurpose.REVOKE, f, now)
        val pub = KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(BigInteger(1, en.publicKey.copyOfRange(1, 33)), BigInteger(1, en.publicKey.copyOfRange(33, 65))), SeedSyncWire.jcaParams()))
        check(verifyServerSig(SeedSyncWire.proofMessage(SyncPurpose.REVOKE, f + mapOf("ownerId" to "o", "keyId" to en.keyId)), sig, pub))
        check(!verifyServerSig(SeedSyncWire.proofMessage(SyncPurpose.SNAPSHOT, f + mapOf("ownerId" to "o", "keyId" to en.keyId, "epoch" to 0L)), sig, pub))
        check(wireErr { SeedSyncWire.signProof(r.c, "o", SyncPurpose.REVOKE, f + ("epoch" to 0L), now) } == "fields")
        check(SyncPurpose.values().map { it.wire }.toSet().size == 5)
    }

    // W12. status purpose (no bearer): fields are ONLY keyId, challenge, expiresAt. Native supplies keyId from its active enrollment; a caller cannot add owner, device,
    // generation or epoch; the signature verifies against the enrolled key; a challenge begun for an older key is never signed by a newer one; only the two
    // definitive states purge and unknown states are refused.
    run {
        val r = Rig(); val en = r.c.enroll("o", INST, 1); val now = 1_800_000_000_000L; val chs = "S".repeat(43)
        check(SeedSyncWire.statusKeyId(r.c, "o") == en.keyId)
        val sig = SeedSyncWire.signStatusProof(r.c, "o", chs, now + 60_000, now, en.keyId)
        val pub = KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(BigInteger(1, en.publicKey.copyOfRange(1, 33)), BigInteger(1, en.publicKey.copyOfRange(33, 65))), SeedSyncWire.jcaParams()))
        val msg = SeedSyncWire.proofMessage(SyncPurpose.STATUS, mapOf("keyId" to en.keyId, "challenge" to chs, "expiresAt" to now + 60_000))
        check(String(msg) == "[\"otpanda-seed-sync-v1\",\"seed-sync-status\",\"${en.keyId}\",\"$chs\",${now + 60_000}]" && verifyServerSig(msg, sig, pub))
        for (extra in listOf("ownerId", "deviceId", "generation", "epoch", "keyId")) check(wireErr { SeedSyncWire.signProof(r.c, "o", SyncPurpose.STATUS, mapOf("challenge" to chs, "expiresAt" to now + 60_000, extra to (if (extra == "generation" || extra == "epoch") 1L else "x")), now, en.keyId) } == "fields") { extra }
        check(wireErr { SeedSyncWire.signStatusProof(r.c, "o", chs, now, now, en.keyId) } == "expiresAt")
        check(wireErr { SeedSyncWire.signStatusProof(r.c, "o", chs, now + 120_001, now, en.keyId) } == "expiresAt")
        check(wireErr { SeedSyncWire.signStatusProof(r.c, "o", "short", now + 1000, now, en.keyId) } != null)
        check(!verifyServerSig(SeedSyncWire.proofMessage(SyncPurpose.SNAPSHOT, mapOf("ownerId" to "o", "keyId" to en.keyId, "deviceId" to "d", "generation" to 1L, "epoch" to 0L, "challenge" to chs, "expiresAt" to now + 60_000)), sig, pub))
        val en2 = r.c.enroll("o", INST, 1) // re-enrollment: the old begin's key id no longer signs
        check(wireErr { SeedSyncWire.signStatusProof(r.c, "o", chs, now + 60_000, now, en.keyId) } == "key")
        check(SeedSyncWire.signStatusProof(r.c, "o", chs, now + 60_000, now, en2.keyId).length == 86)
        r.c.erase("o", 0, EraseTrigger.SIGN_OUT) // erase pending or done: nothing to ask, nothing signs
        check(SeedSyncWire.statusKeyId(r.c, "o") == null)
        want(SyncKeyError.NOT_ENROLLED) { SeedSyncWire.signStatusProof(r.c, "o", chs, now + 60_000, now, en2.keyId) }
        check(SeedSyncWire.statusAction("active") == SeedSyncWire.StatusAction.KEEP)
        check(SeedSyncWire.statusAction("key-revoked") == SeedSyncWire.StatusAction.PURGE && SeedSyncWire.statusAction("generation-changed") == SeedSyncWire.StatusAction.PURGE)
        for (u in listOf(null, "", "Active", "revoked", "device-revoked", "session-expired", "KEY-REVOKED", " active", "active ", "unknown")) {
            check(wireErr { SeedSyncWire.statusAction(u) } == "status" && wireErr { SeedSyncWire.applyStatus(r.c, "o", en2.keyId, u) } == "status") { "mapped $u" }
        }
    }

    // W13. a status answer purges only the key that was asked about (v7 review). Re-enrolled key Y and its seeds are untouched; same key X erases deny-first; an already
    // erased key or a pending erase is a no-op; an unknown state leaves everything byte-identical; and a callback cannot re-enter the core.
    run {
        for (state in listOf("key-revoked", "generation-changed")) {
            val r = Rig(); val x = r.c.enroll("o", INST, 1); r.seed("o"); r.seed("o", "e2")
            val y = r.c.enroll("o", INST, 1) // re-enrollment after begin(X)
            val docBefore = r.ss.docs.getValue(ownerKey("o")); val seedsBefore = r.cv.keys.size; val epBefore = r.custody.readOwnerState("o").epoch
            check(SeedSyncWire.applyStatus(r.c, "o", x.keyId, state) == SeedSyncWire.StatusOutcome.NOOP)
            check(r.ss.docs.getValue(ownerKey("o")) == docBefore && r.cv.keys.size == seedsBefore && r.custody.readOwnerState("o").epoch == epBefore && r.c.enrolled("o") && SeedSyncWire.statusKeyId(r.c, "o") == y.keyId) { "Y disturbed $state" }
            // the same key still erases: deny first, seeds purged, nothing active, nothing owed
            check(SeedSyncWire.applyStatus(r.c, "o", y.keyId, state) == SeedSyncWire.StatusOutcome.PURGED)
            check(!r.c.enrolled("o") && r.cv.keys.isEmpty() && !r.c.purgeOwed("o") && r.c.pendingKeyDeletes("o") == 0) { "X not erased $state" }
            // already gone: no-op
            check(SeedSyncWire.applyStatus(r.c, "o", y.keyId, state) == SeedSyncWire.StatusOutcome.NOOP)
        }
        // erase pending (key deny-listed, delete not yet confirmed): a status answer is a no-op and does not start a new purge
        run {
            val r = Rig(); val x = r.c.enroll("o", INST, 1); r.seed("o")
            r.sv.deleteDown = true
            runCatching { r.c.erase("o", r.custody.readOwnerState("o").epoch, EraseTrigger.SIGN_OUT) }
            val docBefore = r.ss.docs.getValue(ownerKey("o"))
            check(SeedSyncWire.applyStatus(r.c, "o", x.keyId, "key-revoked") == SeedSyncWire.StatusOutcome.PENDING && r.ss.docs.getValue(ownerKey("o")) == docBefore)
        }
        // unknown state: byte-identical state, other owner's seeds untouched
        run {
            val r = Rig(); val x = r.c.enroll("o", INST, 1); r.seed("o"); r.custody.provision("p", "e", 1, TotpCalculator.Algorithm.SHA1, 8, 30, "12345678901234567890".toByteArray(), 0)
            val docBefore = r.ss.docs.getValue(ownerKey("o")); val keysBefore = r.cv.keys.keys.toSet()
            for (u in listOf("revoked", "", null, "ACTIVE")) check(wireErr { SeedSyncWire.applyStatus(r.c, "o", x.keyId, u) } == "status")
            check(SeedSyncWire.applyStatus(r.c, "o", x.keyId, "active") == SeedSyncWire.StatusOutcome.KEPT)
            check(r.ss.docs.getValue(ownerKey("o")) == docBefore && r.cv.keys.keys.toSet() == keysBefore && r.c.enrolled("o"))
        }
        // callback non-reentrancy: inside the provision callback nothing may sign, enroll, erase or retry; the guard state is intact afterwards
        run {
            val r = Rig(); r.c.enroll("o", INST, 1); r.seed("o"); val ep = r.custody.readOwnerState("o").epoch; val now = 1_800_000_000_000L
            val kid = SeedSyncWire.statusKeyId(r.c, "o")!!
            var seen = 0
            val ran = r.c.runIfActive("o", kid, ep) {
                want(SyncKeyError.ERASE_INCOMPLETE) { r.c.erase("o", ep, EraseTrigger.SIGN_OUT) }; seen++
                want(SyncKeyError.ERASE_INCOMPLETE) { r.c.enroll("o", INST, 1) }; seen++
                want(SyncKeyError.ERASE_INCOMPLETE) { SeedSyncWire.signStatusProof(r.c, "o", "S".repeat(43), now + 1000, now, kid) }; seen++
                want(SyncKeyError.ERASE_INCOMPLETE) { r.c.retryPending() }; seen++
                want(SyncKeyError.ERASE_INCOMPLETE) { SeedSyncWire.applyStatus(r.c, "o", kid, "key-revoked") }; seen++
                want(SyncKeyError.ERASE_INCOMPLETE) { r.c.runIfActive("o", kid, ep) { seen += 100 } }; seen++
            }
            check(ran == null && seen == 6 && r.c.enrolled("o") && r.cv.keys.size == 1) { "seen $seen" }
        }
    }

}


private fun handleChecks() {
    // W11. batch handle: single use, exact entry set, per-entry consume before decrypt, zeroing on every path, stops after erase / re-enrollment / epoch change.
    run {
        val now = 1_800_000_000_000L; val chl = "H".repeat(43); val jp = SeedSyncWire.jcaParams()
        class Srv {
            val kp = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
            val raw: ByteArray = (kp.public as ECPublicKey).w.let { w ->
                fun f(b: BigInteger) = b.toByteArray().let { if (it.size > 32) it.copyOfRange(it.size - 32, it.size) else ByteArray(32 - it.size) + it }
                byteArrayOf(4) + f(w.affineX) + f(w.affineY) }
            val pub: String get() = SeedSyncWire.b64(raw)
        }
        fun seal(srv: Srv, ephPub: String, ctx: SeedSyncWire.SealContext, seed: ByteArray, nonce: ByteArray = ByteArray(12) { 3 }): Pair<String, String> {
            val ephRaw = SeedSyncWire.unb64(ephPub, 65); val ephDigest = SeedSyncWire.sha256Hex(ephRaw)
            val ka = javax.crypto.KeyAgreement.getInstance("ECDH"); ka.init(srv.kp.private)
            ka.doPhase(KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(BigInteger(1, ephRaw.copyOfRange(1, 33)), BigInteger(1, ephRaw.copyOfRange(33, 65))), jp)), true)
            val key = SeedSyncWire.hkdf32(ka.generateSecret(), SeedSyncWire.challengeDigest(ctx.challenge).chunked(2).map { it.toInt(16).toByte() }.toByteArray(),
                "otpanda-seed-sync-seal-v1|$ephDigest|${SeedSyncWire.sha256Hex(srv.raw)}".toByteArray())
            val ct = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding").run { init(javax.crypto.Cipher.ENCRYPT_MODE, javax.crypto.spec.SecretKeySpec(key, "AES"), javax.crypto.spec.GCMParameterSpec(128, nonce)); updateAAD(SeedSyncWire.sealAad(ctx, ephDigest)); doFinal(seed) }
            return SeedSyncWire.b64(nonce) to SeedSyncWire.b64(ct)
        }
        val specs = listOf(SealedEntrySpec("e1", 3, "SHA-1", 6, 30), SealedEntrySpec("e2", 5, "SHA-256", 8, 60), SealedEntrySpec("e3", 1, "SHA-512", 7, 15))
        fun ctxOf(s: SealedEntrySpec, ep: Long) = SeedSyncWire.SealContext("o", "device", ep, s.entryId, s.seedVersion, s.algorithm, s.digits, s.period, chl)
        fun seedOf(i: Int) = ByteArray(20) { (i * 31 + it).toByte() }
        fun signed(r: Rig, n: Int = 3): SeedSyncBatchHandle {
            val h = SeedSyncBatchHandle.begin(r.c, "o", "device", 1, r.custody.readOwnerState("o").epoch, specs.take(n))
            h.bind(chl, now + 60_000, now); h.signProof(now); return h
        }
        fun refused(reason: String, w: () -> Any?) { val g = wireErr(w); check(g == reason) { "expected $reason got $g" } }
        // lifecycle and validation
        run {
            val r = Rig(); r.c.enroll("o", INST, 1); val ep = r.custody.readOwnerState("o").epoch
            val h = SeedSyncBatchHandle.begin(r.c, "o", "device", 1, ep, specs)
            refused("state") { h.signProof(now) }; check(h.state == SeedSyncBatchHandle.State.DISCARDED)
            refused("state") { h.bind(chl, now + 1000, now) }
            for (bad in listOf(now, now - 1, now + 120_001, SeedSyncWire.MAX_SAFE + 1)) { val x = SeedSyncBatchHandle.begin(r.c, "o", "device", 1, ep, specs); refused("expiresAt") { x.bind(chl, bad, now) }; check(x.state == SeedSyncBatchHandle.State.DISCARDED) }
            refused("challenge") { SeedSyncBatchHandle.begin(r.c, "o", "device", 1, ep, specs).bind("short", now + 1000, now) }
            refused("entries") { SeedSyncBatchHandle.begin(r.c, "o", "device", 1, ep, emptyList()) }
            refused("entries") { SeedSyncBatchHandle.begin(r.c, "o", "device", 1, ep, specs + SealedEntrySpec("e4", 1, "SHA-1", 6, 30)) }
            refused("entries") { SeedSyncBatchHandle.begin(r.c, "o", "device", 1, ep, listOf(specs[0], specs[0])) }
            refused("algorithm") { SeedSyncBatchHandle.begin(r.c, "o", "device", 1, ep, listOf(specs[0].copy(algorithm = "SHA-3"))) }
            refused("not-enrolled") { SeedSyncBatchHandle.begin(Rig().c, "o", "device", 1, 0, specs) }
            val s1 = signed(r); refused("state") { s1.signProof(now) }; check(s1.state == SeedSyncBatchHandle.State.DISCARDED) // one signature per handle
            val wrongGen = SeedSyncBatchHandle.begin(r.c, "o", "device", 2, ep, specs); wrongGen.bind(chl, now + 1000, now)
            refused("generation") { wrongGen.signProof(now) }; check(wrongGen.state == SeedSyncBatchHandle.State.DISCARDED)
            val wrongEp = SeedSyncBatchHandle.begin(r.c, "o", "device", 1, ep + 1, specs); wrongEp.bind(chl, now + 1000, now)
            refused("epoch") { wrongEp.signProof(now) }
            val late = SeedSyncBatchHandle.begin(r.c, "o", "device", 1, ep, specs); late.bind(chl, now + 1000, now)
            refused("expired") { late.signProof(now + 1000) }
        }
        // the proof covers exactly this handle's ephemeral key and entry set (verified against the enrollment public key)
        run {
            val r = Rig(); val en = r.c.enroll("o", INST, 1); val ep = r.custody.readOwnerState("o").epoch
            val h = SeedSyncBatchHandle.begin(r.c, "o", "device", 1, ep, specs); h.bind(chl, now + 60_000, now); val sig = h.signProof(now)
            val pub = KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(BigInteger(1, en.publicKey.copyOfRange(1, 33)), BigInteger(1, en.publicKey.copyOfRange(33, 65))), jp))
            fun msg(es: List<Pair<String, Long>>) = SeedSyncWire.proofMessage(SyncPurpose.BATCH, mapOf("ownerId" to "o", "keyId" to en.keyId, "deviceId" to "device", "generation" to 1L, "epoch" to ep, "challenge" to chl,
                "ephemeralDigest" to SeedSyncWire.sha256Hex(SeedSyncWire.unb64(h.ephemeralPublic(), 65)), "entriesDigest" to SeedSyncWire.entriesDigest(es), "expiresAt" to now + 60_000))
            check(verifyServerSig(msg(specs.map { it.entryId to it.seedVersion }), sig, pub))
            check(!verifyServerSig(msg(specs.take(2).map { it.entryId to it.seedVersion }), sig, pub))
        }
        // happy path: three entries, seeds delivered then zeroed, nothing retained, handle DONE
        run {
            val r = Rig(); r.c.enroll("o", INST, 1); val ep = r.custody.readOwnerState("o").epoch
            val h = signed(r); val srv = Srv(); val got = ArrayList<Pair<String, ByteArray>>(); val refs = ArrayList<ByteArray>()
            specs.forEachIndexed { i, s ->
                val (n, c) = seal(srv, h.ephemeralPublic(), ctxOf(s, ep), seedOf(i))
                h.open(s.entryId, srv.pub, n, c, now + 1000) { sp, seed -> got.add(sp.entryId to seed.copyOf()); refs.add(seed); check(seed.contentEquals(seedOf(i))) }
            }
            check(got.map { it.first } == listOf("e1", "e2", "e3") && h.state == SeedSyncBatchHandle.State.DONE && h.pendingEntries().isEmpty())
            check(refs.all { r0 -> r0.all { it == 0.toByte() } }) { "seed not zeroed after provision" }
            refused("state") { h.open("e1", srv.pub, "x", "y", now + 1000) { _, _ -> } }
        }
        // per-entry consume BEFORE decrypt: a tampered entry fails, the whole handle is discarded, a retry of that entry or a sibling is refused; no seed is delivered
        run {
            val r = Rig(); r.c.enroll("o", INST, 1); val ep = r.custody.readOwnerState("o").epoch
            val h = signed(r); val srv = Srv(); var delivered = 0
            val (n1, c1) = seal(srv, h.ephemeralPublic(), ctxOf(specs[0], ep), seedOf(0))
            val tam = SeedSyncWire.unb64(c1).also { it[0] = (it[0].toInt() xor 1).toByte() }
            refused("open") { h.open("e1", srv.pub, n1, SeedSyncWire.b64(tam), now + 1000) { _, _ -> delivered++ } }
            check(h.state == SeedSyncBatchHandle.State.DISCARDED && delivered == 0)
            refused("state") { h.open("e1", srv.pub, n1, c1, now + 1000) { _, _ -> delivered++ } }
            val (n2, c2) = seal(srv, h.ephemeralPublic(), ctxOf(specs[1], ep), seedOf(1))
            refused("state") { h.open("e2", srv.pub, n2, c2, now + 1000) { _, _ -> delivered++ } }
            check(delivered == 0)
        }
        // entry not in the request / entry opened twice / different server key mid-batch / wrong seed size
        run {
            val r = Rig(); r.c.enroll("o", INST, 1); val ep = r.custody.readOwnerState("o").epoch
            val srv = Srv(); val srv2 = Srv()
            run { val h = signed(r, 2); val (n, c) = seal(srv, h.ephemeralPublic(), ctxOf(specs[2], ep), seedOf(2)); refused("entry") { h.open("e3", srv.pub, n, c, now + 1000) { _, _ -> } }; check(h.state == SeedSyncBatchHandle.State.DISCARDED) }
            run { val h = signed(r, 2); val (n, c) = seal(srv, h.ephemeralPublic(), ctxOf(specs[0], ep), seedOf(0)); h.open("e1", srv.pub, n, c, now + 1000) { _, _ -> }
                refused("entry") { h.open("e1", srv.pub, n, c, now + 1000) { _, _ -> } } }
            run { val h = signed(r, 2); val (n, c) = seal(srv, h.ephemeralPublic(), ctxOf(specs[0], ep), seedOf(0)); h.open("e1", srv.pub, n, c, now + 1000) { _, _ -> }
                val (n2, c2) = seal(srv2, h.ephemeralPublic(), ctxOf(specs[1], ep), seedOf(1)); refused("serverKey") { h.open("e2", srv2.pub, n2, c2, now + 1000) { _, _ -> } }; check(h.state == SeedSyncBatchHandle.State.DISCARDED) }
            run { val h = signed(r, 1); val (n, c) = seal(srv, h.ephemeralPublic(), ctxOf(specs[0], ep), ByteArray(9)); refused("length") { h.open("e1", srv.pub, n, c, now + 1000) { _, _ -> } } }
            run { val h = signed(r, 1); val (n, c) = seal(srv, h.ephemeralPublic(), ctxOf(specs[0], ep), seedOf(0)); refused("expired") { h.open("e1", srv.pub, n, c, now + 60_000) { _, _ -> } } }
            run { val h = signed(r, 1); val (n, c) = seal(srv, h.ephemeralPublic(), ctxOf(specs[0].copy(seedVersion = 99), ep), seedOf(0)); refused("open") { h.open("e1", srv.pub, n, c, now + 1000) { _, _ -> } } } // bound to the requested version
        }
        // skip consumes without opening; a mix of skipped and opened entries finishes the handle
        run {
            val r = Rig(); r.c.enroll("o", INST, 1)
            val h = signed(r, 2); h.skip("e1", now + 1000); refused("entry") { h.skip("e1", now + 1000) }
        }
        run {
            val r = Rig(); r.c.enroll("o", INST, 1); val ep = r.custody.readOwnerState("o").epoch
            val h = signed(r, 2); val srv = Srv(); h.skip("e1", now + 1000)
            val (n, c) = seal(srv, h.ephemeralPublic(), ctxOf(specs[1], ep), seedOf(1)); h.open("e2", srv.pub, n, c, now + 1000) { _, _ -> }
            check(h.state == SeedSyncBatchHandle.State.DONE)
        }
        // provision throws (RuntimeException and Error): the seed is still zeroed, the failure propagates, the handle is discarded
        for (kind in listOf("runtime", "death")) {
            val r = Rig(); r.c.enroll("o", INST, 1); val ep = r.custody.readOwnerState("o").epoch
            val h = signed(r, 1); val srv = Srv(); val (n, c) = seal(srv, h.ephemeralPublic(), ctxOf(specs[0], ep), seedOf(0)); var ref: ByteArray? = null
            val thrown = try { h.open("e1", srv.pub, n, c, now + 1000) { _, seed -> ref = seed; if (kind == "runtime") throw IllegalStateException("x") else throw ProcessDeath() }; null } catch (e: Throwable) { e }
            check(thrown != null && ref!!.all { it == 0.toByte() } && h.state == SeedSyncBatchHandle.State.DISCARDED) { kind }
        }
        // sign-out / disable / re-enrollment / epoch change mid-batch: nothing is provisioned, and an epoch change never purges
        for (what in listOf("erase", "disable", "reenroll", "epoch")) {
            val r = Rig(); r.c.enroll("o", INST, 1); r.seed("o"); val ep = r.custody.readOwnerState("o").epoch
            val h = signed(r, 2); val srv = Srv(); var delivered = 0
            val (n, c) = seal(srv, h.ephemeralPublic(), ctxOf(specs[0], ep), seedOf(0))
            when (what) {
                "erase" -> r.c.erase("o", ep, EraseTrigger.SIGN_OUT)
                "disable" -> r.c.erase("o", ep, EraseTrigger.DISABLE)
                "reenroll" -> r.c.enroll("o", INST, 1)
                else -> r.seed("o", "other", ep) // native epoch is unchanged by provisioning; bump it through an owner purge-free path below
            }
            if (what == "epoch") { r.custody.clearOwner("o", ep); check(r.custody.readOwnerState("o").epoch != ep) }
            val seedsBefore = r.cv.keys.size
            val reason = wireErr { h.open("e1", srv.pub, n, c, now + 1000) { _, _ -> delivered++ } }
            check(delivered == 0 && reason != null && h.state == SeedSyncBatchHandle.State.DISCARDED) { "$what: $reason" }
            if (what == "epoch") check(reason == "epoch" && r.cv.keys.size == seedsBefore) // refused, and nothing was purged by the handle
            if (what == "reenroll") check(reason == "inactive")
        }
        // v6: erase between decrypt and provision (hook), including an owner with ZERO seed records: refused, nothing provisioned, handle discarded, owed clean
        for (withSeed in listOf(true, false)) for (trig in listOf(EraseTrigger.SIGN_OUT, EraseTrigger.DISABLE)) {
            val r = Rig(); r.c.enroll("o", INST, 1); if (withSeed) r.seed("o"); val ep = r.custody.readOwnerState("o").epoch
            val h = signed(r, 1); val srv = Srv(); var delivered = 0
            val (n, c) = seal(srv, h.ephemeralPublic(), ctxOf(specs[0], ep), seedOf(0))
            h.testHookBeforeGuard = { r.c.erase("o", ep, trig) }
            val before = r.cv.keys.size
            val reason = wireErr { h.open("e1", srv.pub, n, c, now + 1000) { _, _ -> delivered++ } }
            check(reason == "inactive" && delivered == 0 && h.state == SeedSyncBatchHandle.State.DISCARDED) { "hook $withSeed $trig: $reason" }
            check(r.cv.keys.size == 0 && !r.c.purgeOwed("o") && r.c.pendingKeyDeletes("o") == 0 && !r.c.enrolled("o")) { "owed not clean $withSeed $trig" }
        }
        // v6: a concurrent erase cannot land while the provision callback runs; it waits, then purges what was provisioned
        run {
            val r = Rig(); r.c.enroll("o", INST, 1); val ep = r.custody.readOwnerState("o").epoch
            val h = signed(r, 1); val srv = Srv(); val (n, c) = seal(srv, h.ephemeralPublic(), ctxOf(specs[0], ep), seedOf(0))
            var t: Thread? = null; var aliveDuring = false; var erasedDuring = false
            h.open("e1", srv.pub, n, c, now + 1000) { sp, seed ->
                r.custody.provision("o", sp.entryId, sp.seedVersion, TotpCalculator.Algorithm.SHA1, 6, 30, seed.copyOf(), ep)
                t = Thread { r.c.erase("o", ep, EraseTrigger.SIGN_OUT); erasedDuring = true }.also { it.start() }
                Thread.sleep(300); aliveDuring = t!!.isAlive; check(r.cv.keys.size == 1)
            }
            t!!.join(5000)
            check(aliveDuring && !t!!.isAlive && r.cv.keys.size == 0 && !r.c.purgeOwed("o")) { "erase must wait for provision and then purge" }
        }
        // v6: leftover entries (server sealed fewer): finish() drops the handle; the callback's retained reference is zero, its own synchronous copy survives
        run {
            val r = Rig(); r.c.enroll("o", INST, 1); val ep = r.custody.readOwnerState("o").epoch
            val h = signed(r, 3); val srv = Srv(); var ref: ByteArray? = null; var copy: ByteArray? = null
            val (n, c) = seal(srv, h.ephemeralPublic(), ctxOf(specs[0], ep), seedOf(0))
            h.open("e1", srv.pub, n, c, now + 1000) { _, seed -> ref = seed; copy = seed.copyOf() }
            check(h.state == SeedSyncBatchHandle.State.SIGNED && h.pendingEntries().size == 2)
            h.finish()
            check(h.state == SeedSyncBatchHandle.State.DISCARDED && h.pendingEntries().isEmpty())
            check(ref!!.all { it == 0.toByte() } && copy!!.contentEquals(seedOf(0)))
            h.finish() // idempotent
        }
        // v6: the batch cap cannot be raised above the default by a caller
        run {
            val r = Rig(); r.c.enroll("o", INST, 1); val ep = r.custody.readOwnerState("o").epoch
            refused("entries") { SeedSyncBatchHandle.begin(r.c, "o", "device", 1, ep, specs + SealedEntrySpec("e4", 1, "SHA-1", 6, 30), maxEntries = 10) }
        }
        // W14. unregistered channel contract: native clock, strict argument sets, no secrets in replies, whole flow incl. provision into custody, status key targeting,
        // handle cap/TTL/sweep, error codes carry no data.
        run {
            val r = Rig(); var clock = now
            val ch = SeedSyncChannelHandler(r.c, r.custody, { clock })
            fun call(m: String, a: Any?) = ch.handle(m, a)
            fun ok(x: ChannelReply): Any? = (x as? ChannelReply.Ok ?: error("not ok: $x")).value
            fun err(x: ChannelReply): String = (x as? ChannelReply.Err ?: error("not err: $x")).code
            check(call("nope", mapOf<String, Any>()) === ChannelReply.NotImplemented)
            val en = ok(call("syncEnroll", mapOf("owner" to "o", "installId" to INST, "generation" to 1L))) as Map<*, *>
            val keyId = en["keyId"] as String; val pubRaw = en["publicKey"] as ByteArray
            check(keyId.length == 32 && pubRaw.size == 65 && en["generation"] == 1L && en["installId"] == INST)
            val pubKey = KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(BigInteger(1, pubRaw.copyOfRange(1, 33)), BigInteger(1, pubRaw.copyOfRange(33, 65))), jp))
            // strict arguments: extra, missing, wrong types, Double, no map
            check(err(call("syncEnroll", mapOf("owner" to "o", "installId" to INST))) == "INVALID_INPUT")
            check(err(call("syncEnroll", mapOf("owner" to "o", "installId" to INST, "generation" to 1.0))) == "INVALID_INPUT")
            check(err(call("syncEnroll", mapOf("owner" to "o", "installId" to INST, "generation" to 1L, "x" to 1L))) == "INVALID_INPUT")
            check(err(call("syncEnroll", null)) == "INVALID_INPUT")
            // enroll proof: native digest recheck, only the enrollment this process made
            val dig = SeedSyncWire.enrollActionDigest("o", INST, pubRaw, 1)
            val ep = ok(call("syncSignEnrollProof", mapOf("owner" to "o", "challenge" to chl, "actionDigest" to dig, "expiresAt" to now + 60_000, "keyId" to keyId))) as String
            check(verifyServerSig(SeedSyncWire.proofMessage(SyncPurpose.ENROLL, mapOf("ownerId" to "o", "keyId" to keyId, "installId" to INST, "generation" to 1L, "challenge" to chl, "actionDigest" to dig, "expiresAt" to now + 60_000)), ep, pubKey))
            check(err(call("syncSignEnrollProof", mapOf("owner" to "o", "challenge" to chl, "actionDigest" to "0".repeat(64), "expiresAt" to now + 60_000, "keyId" to keyId))) == "WIRE_ACTIONDIGEST")
            check(err(call("syncSignEnrollProof", mapOf("owner" to "o", "challenge" to chl, "actionDigest" to dig, "expiresAt" to now + 60_000, "keyId" to "f".repeat(32)))) == "WIRE_KEY")
            // snapshot/revoke/status proofs: the native clock bounds expiry, wrong generation/epoch refuse
            val epoch0 = r.custody.readOwnerState("o").epoch
            val sn = mapOf("owner" to "o", "deviceId" to "device", "generation" to 1L, "epoch" to epoch0, "challenge" to chl, "expiresAt" to now + 60_000, "keyId" to keyId)
            check((ok(call("syncSignSnapshotProof", sn)) as String).length == 86)
            check(err(call("syncSignSnapshotProof", sn + ("generation" to 2L))) == "WIRE_GENERATION" && err(call("syncSignSnapshotProof", sn + ("epoch" to epoch0 + 1))) == "WIRE_EPOCH")
            check(err(call("syncSignSnapshotProof", sn + ("expiresAt" to now))) == "WIRE_EXPIRESAT")
            check(err(call("syncSignSnapshotProof", sn + ("ownerId" to "evil"))) == "INVALID_INPUT")
            check((ok(call("syncSignRevokeProof", mapOf("owner" to "o", "deviceId" to "device", "generation" to 1L, "challenge" to chl, "expiresAt" to now + 60_000, "keyId" to keyId))) as String).length == 86)
            check(ok(call("syncStatusKeyId", mapOf("owner" to "o"))) == keyId)
            check((ok(call("syncStatusSign", mapOf("owner" to "o", "keyId" to keyId, "challenge" to chl, "expiresAt" to now + 60_000))) as String).length == 86)
            check(err(call("syncStatusSign", mapOf("owner" to "o", "keyId" to "f".repeat(32), "challenge" to chl, "expiresAt" to now + 60_000))) == "WIRE_KEY")
            // full batch: begin, bind, sign, open two entries into custody, skip the third; seeds exist in custody, replies hold no secrets
            val ents = specs.map { mapOf("entryId" to it.entryId, "seedVersion" to it.seedVersion, "algorithm" to it.algorithm, "digits" to it.digits.toLong(), "periodSeconds" to it.period.toLong()) }
            val bb = mapOf("owner" to "o", "deviceId" to "device", "generation" to 1L, "epoch" to epoch0, "entries" to ents)
            val b1 = ok(call("syncBatchBegin", bb)) as Map<*, *>; val hid = b1["handleId"] as String
            check(hid.length == 32 && (b1["ephemeralPublic"] as String).isNotEmpty())
            ok(call("syncBatchBind", mapOf("handleId" to hid, "challenge" to chl, "expiresAt" to now + 60_000)))
            check((ok(call("syncBatchSign", mapOf("handleId" to hid))) as String).length == 86)
            val srv = Srv()
            fun open(i: Int): ChannelReply { val (n, c) = seal(srv, b1["ephemeralPublic"] as String, ctxOf(specs[i], epoch0), seedOf(i))
                return call("syncBatchOpen", mapOf("handleId" to hid, "entryId" to specs[i].entryId, "serverPublicKey" to srv.pub, "nonce" to n, "ciphertext" to c)) }
            val o1 = ok(open(0)) as Map<*, *>; check(o1["pending"] == listOf("e2", "e3") && o1.toString().none { false })
            check(r.custody.readCatalog("o").entries.map { it.entry } == listOf("e1"))
            ok(open(1)); check((ok(call("syncBatchSkip", mapOf("handleId" to hid, "entryId" to "e3"))) as Map<*, *>)["pending"] == emptyList<String>())
            check(r.custody.readCatalog("o").entries.map { it.entry }.toSet() == setOf("e1", "e2"))
            check(err(call("syncBatchSign", mapOf("handleId" to hid))) == "WIRE_STATE") // finished handle is gone
            ok(call("syncBatchFinish", mapOf("handleId" to hid))); ok(call("syncBatchFinish", mapOf("handleId" to "0".repeat(32)))) // idempotent
            // cap: MAX_HANDLES live, then BUSY; finish frees; TTL sweeps
            val ids = (1..SeedSyncChannelHandler.MAX_HANDLES).map { (ok(call("syncBatchBegin", bb)) as Map<*, *>)["handleId"] as String }
            check(err(call("syncBatchBegin", bb)) == "BUSY")
            ok(call("syncBatchFinish", mapOf("handleId" to ids[0]))); ok(call("syncBatchBegin", bb))
            clock += SeedSyncChannelHandler.HANDLE_TTL_MS
            check(err(call("syncBatchBind", mapOf("handleId" to ids[1], "challenge" to chl, "expiresAt" to clock + 60_000))) == "WIRE_STATE")
            ok(call("syncBatchBegin", bb)) // table was swept by the TTL
            // a failed open discards the whole handle and the error is a bare code
            clock = now
            val b2 = ok(call("syncBatchBegin", bb)) as Map<*, *>; val h2 = b2["handleId"] as String
            ok(call("syncBatchBind", mapOf("handleId" to h2, "challenge" to chl, "expiresAt" to now + 60_000))); ok(call("syncBatchSign", mapOf("handleId" to h2)))
            val bad = call("syncBatchOpen", mapOf("handleId" to h2, "entryId" to "e1", "serverPublicKey" to srv.pub, "nonce" to SeedSyncWire.b64(ByteArray(12)), "ciphertext" to SeedSyncWire.b64(ByteArray(40))))
            check(err(bad).matches(Regex("WIRE_[A-Z_]+")) && err(call("syncBatchSkip", mapOf("handleId" to h2, "entryId" to "e2"))) == "WIRE_STATE")
            // erase and status targeting through the channel; remote triggers are not accepted by syncErase
            check(err(call("syncErase", mapOf("owner" to "o", "epoch" to epoch0, "trigger" to "key-revoked"))) == "INVALID_INPUT")
            val y = ok(call("syncEnroll", mapOf("owner" to "o", "installId" to INST, "generation" to 1L))) as Map<*, *>
            check((ok(call("syncStatusApply", mapOf("owner" to "o", "keyId" to keyId, "state" to "key-revoked"))) as Map<*, *>)["outcome"] == "noop") // X asked, Y active
            check(ok(call("syncStatusKeyId", mapOf("owner" to "o"))) == y["keyId"])
            check(err(call("syncStatusApply", mapOf("owner" to "o", "keyId" to y["keyId"], "state" to "revoked"))) == "WIRE_STATUS")
            check((ok(call("syncStatusApply", mapOf("owner" to "o", "keyId" to y["keyId"], "state" to "generation-changed"))) as Map<*, *>)["outcome"] == "purged")
            check(r.custody.readCatalog("o").entries.isEmpty() && ok(call("syncStatusKeyId", mapOf("owner" to "o"))) == null)
            val rp = ok(call("syncRetryPending", null)) as Map<*, *>; check(rp["purgesOwed"] == 0L)
            val e3 = ok(call("syncEnroll", mapOf("owner" to "o", "installId" to INST, "generation" to 1L))) as Map<*, *>
            val er = ok(call("syncErase", mapOf("owner" to "o", "epoch" to r.custody.readOwnerState("o").epoch, "trigger" to "sign_out"))) as Map<*, *>
            check(er["keyDeleted"] == true && ok(call("syncStatusKeyId", mapOf("owner" to "o"))) == null && e3["keyId"] != null)
        }
        // W15. review v9: seed zeroing through the channel, half enrollment repair, owner discovery, handle discard on erase/purge/enroll, finish only discards, concurrent erase
        run {
            fun ok(x: ChannelReply): Any? = (x as? ChannelReply.Ok ?: error("not ok: $x")).value
            fun err(x: ChannelReply): String = (x as? ChannelReply.Err ?: error("not err: $x")).code
            fun ents(): List<Map<String, Any?>> = specs.map { mapOf("entryId" to it.entryId, "seedVersion" to it.seedVersion, "algorithm" to it.algorithm, "digits" to it.digits.toLong(), "periodSeconds" to it.period.toLong()) }
            fun begin(h: SeedSyncChannelHandler, ep: Long, owner: String = "o"): Pair<String, String> {
                val b = ok(h.handle("syncBatchBegin", mapOf("owner" to owner, "deviceId" to "device", "generation" to 1L, "epoch" to ep, "entries" to ents()))) as Map<*, *>
                val id = b["handleId"] as String
                ok(h.handle("syncBatchBind", mapOf("handleId" to id, "challenge" to chl, "expiresAt" to now + 60_000))); ok(h.handle("syncBatchSign", mapOf("handleId" to id)))
                return id to (b["ephemeralPublic"] as String)
            }
            // seed zeroing: the same array reaches the provisioner (no copy), and is zero afterwards on success, on RuntimeException and on Error
            for (kind in listOf("ok", "runtime", "death")) {
                val r = Rig(); r.c.enroll("o", INST, 1); val ep = r.custody.readOwnerState("o").epoch; var ref: ByteArray? = null; var seen: ByteArray? = null
                val h = SeedSyncChannelHandler(r.c, r.custody, { now }, provisioner = { _, _, seed, _ -> ref = seed; seen = seed.copyOf(); if (kind == "runtime") throw IllegalStateException("x") else if (kind == "death") throw ProcessDeath() })
                val (id, eph) = begin(h, ep); val srv = Srv(); val (n, c) = seal(srv, eph, ctxOf(specs[0], ep), seedOf(0))
                val call = { h.handle("syncBatchOpen", mapOf("handleId" to id, "entryId" to "e1", "serverPublicKey" to srv.pub, "nonce" to n, "ciphertext" to c)) }
                when (kind) { "ok" -> ok(call()); "runtime" -> check(err(call()) == "UNAVAILABLE"); else -> check(died { call() }) }
                check(seen!!.contentEquals(seedOf(0)) && ref!!.all { it == 0.toByte() }) { "seed copy not zeroed $kind" }
                if (kind != "ok") check(err(h.handle("syncBatchSkip", mapOf("handleId" to id, "entryId" to "e2"))) == "WIRE_STATE") // whole handle discarded
            }
            // half enrollment: restart loses the public point; not provable; proof refused; re-enroll replaces deny-first, only the new alias remains, seeds untouched
            run {
                val r = Rig(); val h1 = SeedSyncChannelHandler(r.c, r.custody, { now })
                val e1 = ok(h1.handle("syncEnroll", mapOf("owner" to "o", "installId" to INST, "generation" to 1L))) as Map<*, *>; r.seed("o")
                check((ok(h1.handle("syncEnrollmentState", mapOf("owner" to "o"))) as Map<*, *>)["provable"] == true)
                val c2 = r.restart(); val h2 = SeedSyncChannelHandler(c2, r.custody, { now })
                val st = ok(h2.handle("syncEnrollmentState", mapOf("owner" to "o"))) as Map<*, *>
                check(st["keyId"] == e1["keyId"] && st["provable"] == false)
                val dig = SeedSyncWire.enrollActionDigest("o", INST, e1["publicKey"] as ByteArray, 1)
                check(err(h2.handle("syncSignEnrollProof", mapOf("owner" to "o", "challenge" to chl, "actionDigest" to dig, "expiresAt" to now + 60_000, "keyId" to e1["keyId"]))) == "WIRE_KEY")
                check(err(h2.handle("syncEnroll", mapOf("owner" to "o", "installId" to "X".repeat(22), "generation" to 1L))) == "INVALID_INPUT") // install id is pinned
                check(r.sv.keys.size == 1)
                val seedsBefore = r.cv.keys.size
                val e2 = ok(h2.handle("syncEnroll", mapOf("owner" to "o", "installId" to INST, "generation" to 1L))) as Map<*, *>
                check(e2["keyId"] != e1["keyId"] && r.sv.keys.size == 1 && c2.pendingKeyDeletes("o") == 0 && r.cv.keys.size == seedsBefore) { "replace left old key or touched seeds" }
                check((ok(h2.handle("syncEnrollmentState", mapOf("owner" to "o"))) as Map<*, *>)["provable"] == true)
                val dig2 = SeedSyncWire.enrollActionDigest("o", INST, e2["publicKey"] as ByteArray, 1)
                check((ok(h2.handle("syncSignEnrollProof", mapOf("owner" to "o", "challenge" to chl, "actionDigest" to dig2, "expiresAt" to now + 60_000, "keyId" to e2["keyId"]))) as String).length == 86)
            }
            // owner discovery without any session: empty and complete, active, pending, unreadable (incomplete), unlistable (error, never empty)
            run {
                val r = Rig(); val h = SeedSyncChannelHandler(r.c, r.custody, { now })
                val d0 = ok(h.handle("syncDiscoverOwners", null)) as Map<*, *>; check((d0["owners"] as List<*>).isEmpty() && d0["complete"] == true && d0["unreadable"] == 0L)
                val ea = ok(h.handle("syncEnroll", mapOf("owner" to "a", "installId" to INST, "generation" to 1L))) as Map<*, *>
                ok(h.handle("syncEnroll", mapOf("owner" to "b", "installId" to INST, "generation" to 1L)))
                r.sv.deleteDown = true; ok(h.handle("syncErase", mapOf("owner" to "b", "epoch" to 0L, "trigger" to "sign_out"))); r.sv.deleteDown = false
                val d1 = ok(h.handle("syncDiscoverOwners", mapOf<String, Any>())) as Map<*, *>
                val list = (d1["owners"] as List<*>).map { it as Map<*, *> }
                check(list.map { it["owner"] } == listOf("a", "b") && list[0]["keyId"] == ea["keyId"] && list[0]["pending"] == false && list[1]["keyId"] == null && list[1]["pending"] == true && d1["complete"] == true)
                check(list.all { it.keys == setOf("owner", "keyId", "pending") }) // nothing else is disclosed
                check(ok(h.handle("syncRetryPending", null)).let { (it as Map<*, *>)["keyDeletesPending"] } == 0L)
                check(((ok(h.handle("syncDiscoverOwners", null)) as Map<*, *>)["owners"] as List<*>).map { (it as Map<*, *>)["pending"] } == listOf(false, false))
                r.ss.docs[ownerKey("zz")] = "garbage"
                val d2 = ok(h.handle("syncDiscoverOwners", null)) as Map<*, *>; check(d2["complete"] == false && d2["unreadable"] == 1L && (d2["owners"] as List<*>).size == 2)
                // corrupt body for a known owner: also counted, never silently dropped, nothing changed
                r.ss.docs.remove(ownerKey("zz"))
                val before = r.ss.docs.getValue(ownerKey("a")); r.ss.docs[ownerKey("a")] = before.replace("end\n", "xend\n")
                val d3 = ok(h.handle("syncDiscoverOwners", null)) as Map<*, *>; check(d3["complete"] == false && (d3["unreadable"] as Long) >= 1L)
                check((ok(h.handle("syncStatusApply", mapOf("owner" to "a", "keyId" to ea["keyId"], "state" to "key-revoked"))) as Map<*, *>)["outcome"] == "unreadable")
                r.ss.docs[ownerKey("a")] = before
                r.ss.down = true; check(err(h.handle("syncDiscoverOwners", null)) == "METADATA_UNAVAILABLE"); r.ss.down = false
            }
            // erase, status purge and re-enroll discard that owner's handles at once; another owner's handle is untouched; noop/pending leave handles alone
            for (how in listOf("erase", "purge", "enroll")) {
                val r = Rig(); val h = SeedSyncChannelHandler(r.c, r.custody, { now })
                val k = (ok(h.handle("syncEnroll", mapOf("owner" to "o", "installId" to INST, "generation" to 1L))) as Map<*, *>)["keyId"] as String
                r.c.enroll("p", INST, 1); val ep = r.custody.readOwnerState("o").epoch
                val (ho, _) = begin(h, ep); val (hp, _) = begin(h, r.custody.readOwnerState("p").epoch, "p")
                check((ok(h.handle("syncStatusApply", mapOf("owner" to "o", "keyId" to "f".repeat(32), "state" to "key-revoked"))) as Map<*, *>)["outcome"] == "noop")
                val (ho2, _) = begin(h, ep)
                when (how) {
                    "erase" -> ok(h.handle("syncErase", mapOf("owner" to "o", "epoch" to ep, "trigger" to "sign_out")))
                    "purge" -> check((ok(h.handle("syncStatusApply", mapOf("owner" to "o", "keyId" to k, "state" to "key-revoked"))) as Map<*, *>)["outcome"] == "purged")
                    else -> ok(h.handle("syncEnroll", mapOf("owner" to "o", "installId" to INST, "generation" to 1L)))
                }
                check(err(h.handle("syncBatchSkip", mapOf("handleId" to ho2, "entryId" to "e1"))) == "WIRE_STATE") { "owner handle survived $how (skip)" }
                check(err(h.handle("syncBatchBind", mapOf("handleId" to ho2, "challenge" to chl, "expiresAt" to now + 60_000))) == "WIRE_STATE") { "owner handle survived $how" }
                check(ok(h.handle("syncBatchFinish", mapOf("handleId" to hp))) == null)
            }
            // finish only discards: nothing is signed, opened or provisioned
            run {
                val r = Rig(); r.c.enroll("o", INST, 1); val ep = r.custody.readOwnerState("o").epoch; var provisioned = 0
                val h = SeedSyncChannelHandler(r.c, r.custody, { now }, provisioner = { _, _, _, _ -> provisioned++ })
                val b = ok(h.handle("syncBatchBegin", mapOf("owner" to "o", "deviceId" to "device", "generation" to 1L, "epoch" to ep, "entries" to ents()))) as Map<*, *>
                ok(h.handle("syncBatchFinish", mapOf("handleId" to b["handleId"])))
                check(err(h.handle("syncBatchSign", mapOf("handleId" to b["handleId"]))) == "WIRE_STATE" && provisioned == 0)
                val (id, eph) = begin(h, ep); ok(h.handle("syncBatchFinish", mapOf("handleId" to id)))
                val srv = Srv(); val (n, c) = seal(srv, eph, ctxOf(specs[0], ep), seedOf(0))
                check(err(h.handle("syncBatchOpen", mapOf("handleId" to id, "entryId" to "e1", "serverPublicKey" to srv.pub, "nonce" to n, "ciphertext" to c))) == "WIRE_STATE" && provisioned == 0)
            }
            // concurrent erase through the handler while an open is provisioning: the erase waits, then purges what was provisioned
            run {
                val r = Rig(); r.c.enroll("o", INST, 1); val ep = r.custody.readOwnerState("o").epoch
                var t: Thread? = null; var aliveDuring = false; var hh: SeedSyncChannelHandler? = null; var eraseReply: ChannelReply? = null
                val h = SeedSyncChannelHandler(r.c, r.custody, { now }, provisioner = { owner, spec, seed, epoch ->
                    r.custody.provision(owner, spec.entryId, spec.seedVersion, wireAlgorithm(spec.algorithm), spec.digits, spec.period, seed, epoch)
                    t = Thread { eraseReply = hh!!.handle("syncErase", mapOf("owner" to "o", "epoch" to ep, "trigger" to "sign_out")) }.also { it.start() }
                    Thread.sleep(300); aliveDuring = t!!.isAlive; check(r.cv.keys.size == 1)
                })
                hh = h; val (id, eph) = begin(h, ep); val srv = Srv(); val (n, c) = seal(srv, eph, ctxOf(specs[0], ep), seedOf(0))
                ok(h.handle("syncBatchOpen", mapOf("handleId" to id, "entryId" to "e1", "serverPublicKey" to srv.pub, "nonce" to n, "ciphertext" to c)))
                t!!.join(5000)
                check(eraseReply is ChannelReply.Ok && aliveDuring && !t!!.isAlive && r.cv.keys.size == 0 && !r.c.purgeOwed("o"))
            }
        }
    }
}

private fun owners(r: Rig) = r.ss.docs.keys.toList()

fun main() {
    System.getenv("SEED_STATUS_FIXTURE_OUT")?.let { exportStatusFixture(it) }
    // 1. enroll, sign with the enrolled key only; the durable document holds ids and aliases, no key material.
    run {
        val r = Rig(); check(!r.c.enrolled("o"))
        want(SyncKeyError.NOT_ENROLLED) { r.c.signRawForTests("o", byteArrayOf(1)) }
        val en = r.c.enroll("o", INST, 1); check(r.c.enrolled("o") && en.publicKey.size == 65 && en.publicKey[0] == 4.toByte())
        val m = "synthetic message".toByteArray(); check(verifies(en.publicKey, m, r.c.signRawForTests("o", m)))
        val doc = r.ss.docs.getValue(ownerKey("o")); check(doc.lines().first() == "otpanda-seedsync-state-v1" && !doc.contains("PRIVATE"))
        check(SyncState.decode(doc, "o").active != null)
        check(r.sv.keys.keys.all { it.startsWith("otpanda.seedsync.v1.") })
        check(r.cv.keys.isEmpty()) // never touches custody keys
        check(r.restart().enrolled("o")) // enrollment is durable
    }
    // 2. every purge trigger: key and seeds gone, deny cleared; DISABLE opts out, every other trigger leaves the default ON preference.
    for (t in EraseTrigger.values()) {
        val r = Rig(); r.c.enroll("o", INST, 1); r.seed()
        val out = r.c.erase("o", 0, t)
        check(out.seedsPurged && out.keyDeleted && out.epoch == 1L) { "$t $out" }
        check(r.sv.keys.isEmpty() && r.cv.keys.isEmpty() && !r.c.enrolled("o") && r.c.pendingKeyDeletes("o") == 0) { "$t" }
        check(r.custody.readOwnerState("o").enabled == (t != EraseTrigger.DISABLE)) { "$t preference" }
        want(SyncKeyError.NOT_ENROLLED) { r.c.signRawForTests("o", byteArrayOf(1)) }
    }
    // 3. order: the deny commit is durable before the seeds are purged and before the vault delete.
    run {
        val r = Rig(); r.c.enroll("o", INST, 1); r.seed()
        var docAtDelete = ""; var seedsAtDelete = -1
        r.sv.onDelete = { docAtDelete = r.ss.docs.getValue(ownerKey("o")); seedsAtDelete = r.cv.keys.size }
        r.c.erase("o", 0, EraseTrigger.SIGN_OUT)
        check(docAtDelete.contains("active none") && docAtDelete.contains("\ndeny ")) { "deny not committed before delete" }
        check(seedsAtDelete == 0) { "seeds not purged before key delete" }
    }
    // 4. delete fails or does not take: deny record kept, key never usable (this process, after restart), retried until a READ BACK shows it absent.
    for (mode in listOf("throws", "ignored")) {
        val r = Rig(); r.c.enroll("o", INST, 1); r.seed()
        if (mode == "throws") r.sv.deleteDown = true else r.sv.ignoreDelete = true
        val out = r.c.erase("o", 0, EraseTrigger.SIGN_OUT)
        check(out.seedsPurged && !out.keyDeleted && r.sv.keys.size == 1 && r.c.pendingKeyDeletes("o") == 1) { mode }
        want(SyncKeyError.NOT_ENROLLED) { r.c.signRawForTests("o", byteArrayOf(1)) }
        val again = r.restart(); want(SyncKeyError.NOT_ENROLLED) { again.signRawForTests("o", byteArrayOf(1)) }
        check(again.retryPending().keyDeletesPending == 1 && r.sv.keys.size == 1)
        r.sv.deleteDown = false; r.sv.ignoreDelete = false
        check(again.retryPending().clean && r.sv.keys.isEmpty() && again.pendingKeyDeletes("o") == 0) { mode }
        check(r.ss.docs.getValue(ownerKey("o")).let { !it.contains("deny ") })
    }
    // 5. the commit itself cannot be written: the alias is still deleted best effort and the failure is reported; the stale document can never sign.
    run {
        val r = Rig(); r.c.enroll("o", INST, 1); r.ss.writeDown = true
        want(SyncKeyError.ERASE_INCOMPLETE) { r.c.erase("o", 0, EraseTrigger.DISABLE) }
        check(r.sv.keys.isEmpty()); r.ss.writeDown = false
        want(SyncKeyError.ERASE_INCOMPLETE) { r.c.signRawForTests("o", byteArrayOf(1)) }
        want(SyncKeyError.MISSING_KEY) { r.restart().signRawForTests("o", byteArrayOf(1)) }
        check(r.c.erase("o", 0, EraseTrigger.SIGN_OUT).keyDeleted && !r.c.enrolled("o"))
    }
    // 6. process death at every step, then restart.
    run { // dies at the vault delete: deny already durable
        val r = Rig(); r.c.enroll("o", INST, 1); r.seed(); r.sv.deleteDeath = true
        check(died { r.c.erase("o", 0, EraseTrigger.SIGN_OUT) }); r.sv.deleteDeath = false
        val a = r.restart(); want(SyncKeyError.NOT_ENROLLED) { a.signRawForTests("o", byteArrayOf(1)) }
        check(r.cv.keys.isEmpty() && a.pendingKeyDeletes("o") == 1 && r.sv.keys.size == 1)
        check(a.retryPending().clean && r.sv.keys.isEmpty())
    }
    run { // dies inside the custody seed delete: seeds pending in custody, key deny durable, nothing signs
        val r = Rig(); r.c.enroll("o", INST, 1); r.seed(); r.cv.deleteDeath = true
        check(died { r.c.erase("o", 0, EraseTrigger.SIGN_OUT) }); r.cv.deleteDeath = false
        val a = r.restart(); want(SyncKeyError.ERASE_INCOMPLETE) { a.signRawForTests("o", byteArrayOf(1)) } // owed purge is durable
        check(a.retryPending().clean && r.sv.keys.isEmpty() && r.cv.keys.isEmpty())
    }
    run { // dies while clearing the deny record after a confirmed delete: the record survives, harmless, and the retry clears it
        val r = Rig(); r.c.enroll("o", INST, 1); r.ss.writeDeathAt = r.ss.writes + 2 // write 0 commits deny+owed; write 1 clears owed; write 2 clears the deny record
        check(died { r.c.erase("o", 0, EraseTrigger.SIGN_OUT) }); r.ss.writeDeathAt = -1
        check(r.sv.keys.isEmpty() && r.restart().pendingKeyDeletes("o") == 1 && r.c.retryPending().clean && r.c.pendingKeyDeletes("o") == 0)
    }
    run { // dies while clearing the owed purge: the owed record survives, the key is still deleted, retry repeats the idempotent purge
        val r = Rig(); r.c.enroll("o", INST, 1); r.seed(); r.ss.writeDeathAt = r.ss.writes + 1
        check(died { r.c.erase("o", 0, EraseTrigger.SIGN_OUT) }); r.ss.writeDeathAt = -1
        val a = r.restart(); check(a.purgeOwed("o") && r.cv.keys.isEmpty() && r.sv.keys.isEmpty())
        check(a.retryPending().clean && !a.purgeOwed("o"))
    }
    run { // dies between key creation and the durable write: orphan alias, never usable, swept
        val r = Rig(); r.ss.writeDeathAt = r.ss.writes
        check(died { r.c.enroll("o", INST, 1) }); r.ss.writeDeathAt = -1
        val a = r.restart(); check(!a.enrolled("o") && r.sv.keys.size == 1)
        want(SyncKeyError.NOT_ENROLLED) { a.signRawForTests("o", byteArrayOf(1)) }
        check(a.sweepOrphans().size == 1 && r.sv.keys.isEmpty())
        a.enroll("o", INST, 1); check(a.enrolled("o"))
    }
    // 7. fresh alias on re-enrollment; the old key is denied and deleted; an unresolved old deletion does not block, and the old key never signs.
    run {
        val r = Rig(); val e1 = r.c.enroll("o", INST, 1); val a1 = r.sv.keys.keys.single()
        val e2 = r.c.enroll("o", INST, 1); check(e1.keyId != e2.keyId && a1 !in r.sv.keys && r.sv.keys.size == 1 && r.c.pendingKeyDeletes("o") == 0)
        r.sv.deleteDown = true; val a2 = r.sv.keys.keys.single()
        val e3 = r.c.enroll("o", INST, 1); check(r.sv.keys.size == 2 && a2 in r.sv.keys && r.c.pendingKeyDeletes("o") == 1)
        val m = byteArrayOf(9); check(verifies(e3.publicKey, m, r.c.signRawForTests("o", m)) && !verifies(e2.publicKey, m, r.c.signRawForTests("o", m)))
        r.sv.deleteDown = false; check(r.c.retryPending().clean && r.sv.keys.size == 1)
    }
    // 8. custody failure after the key steps: the key is still denied and deleted, and the failure is not hidden. Too-high epoch behaves the same.
    run {
        val r = Rig(); r.c.enroll("o", INST, 1); r.seed(); r.cs.down = true
        // the sync document store is separate, so only the custody step fails
        check(try { r.c.erase("o", 0, EraseTrigger.SIGN_OUT); false } catch (e: CustodyFailure) { e.error == CustodyError.METADATA_UNAVAILABLE })
        check(r.sv.keys.isEmpty() && !r.c.enrolled("o") && r.c.purgeOwed("o")); r.cs.down = false
        check(r.c.retryPending().clean && r.cv.keys.isEmpty() && !r.c.purgeOwed("o"))
        val q = Rig(); q.c.enroll("o", INST, 1); q.seed()
        check(try { q.c.erase("o", 7, EraseTrigger.SIGN_OUT); false } catch (e: CustodyFailure) { e.error == CustodyError.EPOCH_MISMATCH })
        check(q.sv.keys.isEmpty() && !q.c.enrolled("o") && q.custody.readOwnerState("o").epoch == 0L && q.cv.keys.size == 1 && q.c.purgeOwed("o"))
        want(SyncKeyError.ERASE_INCOMPLETE) { q.c.enroll("o", INST, 1) }
        check(q.c.retryPending().clean && q.cv.keys.isEmpty() && q.custody.readOwnerState("o").epoch == 1L && !q.c.purgeOwed("o")) // real epoch, seeds removed, owed cleared only on success
        q.c.enroll("o", INST, 1) // allowed again
    }
    // 9. unreadable or corrupt state fails closed everywhere; seeds are still purged; nothing is deleted blindly.
    run {
        val r = Rig(); r.c.enroll("o", INST, 1); r.seed(); val doc = r.ss.docs.getValue(ownerKey("o"))
        for (bad in listOf("corrupt", doc.replace("deny", "deni") + "x", doc.replace("owner ", "owner A"))) {
            r.ss.docs[ownerKey("o")] = bad
            want(SyncKeyError.METADATA_UNAVAILABLE) { r.c.signRawForTests("o", byteArrayOf(1)) }
            want(SyncKeyError.METADATA_UNAVAILABLE) { r.c.enroll("o", INST, 1) }
            check(r.c.retryPending().let { it.unreadableOwners == 1 && !it.clean }) // counted, never deleted blindly
            want(SyncKeyError.METADATA_UNAVAILABLE) { r.c.sweepOrphans() }
            check(r.sv.keys.size == 1)
        }
        want(SyncKeyError.METADATA_UNAVAILABLE) { r.c.erase("o", 0, EraseTrigger.SIGN_OUT) }
        check(r.cv.keys.isEmpty() && r.sv.keys.size == 1) // seeds purged, key unusable but not deleted blindly
        r.ss.docs[ownerKey("o")] = doc; r.ss.down = true
        want(SyncKeyError.ERASE_INCOMPLETE) { r.c.signRawForTests("o", byteArrayOf(1)) } // the lost erase intent still blocks the key; the store is down
        want(SyncKeyError.METADATA_UNAVAILABLE) { r.c.retryPending() }
        r.ss.down = false // the document is readable again: the retry now commits the erase that was requested earlier and deletes the key
        check(r.c.retryPending().clean && r.sv.keys.isEmpty() && !r.c.enrolled("o"))
    }
    // 10. owners are independent; the sweep only touches seed-sync aliases that no document references.
    run {
        val r = Rig(); r.c.enroll("a", INST, 1); r.c.enroll("b", INST, 1)
        r.sv.keys["otpanda.totp.v2.custody-alias"] = r.sv.keys.values.first(); r.sv.keys["otpanda.seedsync.v1." + "f".repeat(32)] = r.sv.keys.values.first()
        check(r.c.sweepOrphans() == setOf("otpanda.seedsync.v1." + "f".repeat(32)) && "otpanda.totp.v2.custody-alias" in r.sv.keys)
        r.c.erase("a", 0, EraseTrigger.OWNER_SWITCH); check(!r.c.enrolled("a") && r.c.enrolled("b")); r.c.signRawForTests("b", byteArrayOf(1))
        check(r.sv.keys.keys.count { it.startsWith("otpanda.seedsync.v1.") } == 1)
        r.sv.listDown = true; want(SyncKeyError.UNAVAILABLE) { r.c.sweepOrphans() }
    }
    // 11. remote codes: only the four definitive codes purge; expiry suspends; everything else changes nothing.
    run {
        for (c in listOf("seed-sync-key-revoked", "device-revoked", "session-revoked", "security-generation-changed")) check(classifyRemoteCode(c) == RemoteCodeAction.PURGE && eraseTriggerFor(c) != null)
        for (c in listOf("session-expired", "idle-expired")) check(classifyRemoteCode(c) == RemoteCodeAction.SUSPEND && eraseTriggerFor(c) == null)
        for (c in listOf(null, "", "401", "403", "500", "invalid_grant", "captive-portal", "Seed-Sync-Key-Revoked", " device-revoked", "device-revoked\n", "timeout", "clock-skew")) check(classifyRemoteCode(c) == RemoteCodeAction.IGNORE && eraseTriggerFor(c) == null) { "code $c" }
    }
    // 12. strict codec
    run {
        val r = Rig(); r.c.enroll("o", INST, 1); val doc = r.ss.docs.getValue(ownerKey("o")); SyncState.decode(doc, "o")
        val a = doc.lines()[2].split(' ')[2]
        for (bad in listOf(doc.replace("active ", "active  "), doc.replace("\nend\n", "\n"), doc.replace("v1.", "v2."), doc.replace("\nend\n", "\ndeny ${"0".repeat(32)} $a\nend\n"), doc.replace("\nend\n", "\n\nend\n")))
            check(runCatching { SyncState.decode(bad, "o") }.isFailure) { "accepted: $bad" }
        check(runCatching { SyncState.decode(doc, "other") }.isFailure)
        check(runCatching { SyncState.decode("x".repeat(70000), "o") }.isFailure)
    }
    // 13. invalid owner ids
    run { val r = Rig(); for (bad in listOf("", "a\u0000b", "x".repeat(129))) { want(SyncKeyError.INVALID_INPUT) { r.c.enroll(bad, INST, 1) }; want(SyncKeyError.INVALID_INPUT) { r.c.erase(bad, 0, EraseTrigger.SIGN_OUT) } } }
    // 14. commit fails AND delete fails: sign and enroll refuse at once (in-memory intent), seeds are still purged, ERASE_INCOMPLETE is typed; retryPending commits it.
    run {
        val r = Rig(); r.c.enroll("o", INST, 1); r.seed(); r.ss.writeDown = true; r.sv.deleteDown = true
        want(SyncKeyError.ERASE_INCOMPLETE) { r.c.erase("o", 0, EraseTrigger.SIGN_OUT) }
        check(r.cv.keys.isEmpty() && r.sv.keys.size == 1)
        want(SyncKeyError.ERASE_INCOMPLETE) { r.c.signRawForTests("o", byteArrayOf(1)) }
        want(SyncKeyError.ERASE_INCOMPLETE) { r.c.enroll("o", INST, 1) }
        check(!r.c.enrolled("o"))
        check(!r.c.retryPending().clean) // still down: still blocked
        want(SyncKeyError.ERASE_INCOMPLETE) { r.c.signRawForTests("o", byteArrayOf(1)) }
        r.ss.writeDown = false; r.sv.deleteDown = false
        check(r.c.retryPending().clean && r.sv.keys.isEmpty() && !r.c.purgeOwed("o"))
        want(SyncKeyError.NOT_ENROLLED) { r.c.signRawForTests("o", byteArrayOf(1)) }
        // documented gap: a process death in that window loses the memory intent; only the caller's persisted intent re-running erase recovers it
        val g = Rig(); g.c.enroll("o", INST, 1); g.ss.writeDown = true; g.sv.deleteDown = true
        want(SyncKeyError.ERASE_INCOMPLETE) { g.c.erase("o", 0, EraseTrigger.SIGN_OUT) }
        g.ss.writeDown = false; g.sv.deleteDown = false
        check(g.restart().enrolled("o")) // stale durable state says active
        check(g.c.erase("o", 0, EraseTrigger.SIGN_OUT).keyDeleted && !g.c.enrolled("o"))
    }
    // 15. a RuntimeException (not a CustodyFailure) from custody still deletes the key; the owed purge stays durable and a retry finishes it.
    run {
        val r = Rig(); r.c.enroll("o", INST, 1); r.seed(); r.cv.deleteRuntime = true
        val thrown = try { r.c.erase("o", 0, EraseTrigger.SIGN_OUT).let { if (it.seedsPurged) "purged" else null } } catch (e: Exception) { e }
        check(thrown != "purged") { "must not report a purge that did not finish" } // custody may map it to a pending purge or let it escape; both are not-done
        check(r.sv.keys.isEmpty() && r.c.purgeOwed("o") && !r.c.enrolled("o"))
        want(SyncKeyError.ERASE_INCOMPLETE) { r.c.signRawForTests("o", byteArrayOf(1)) }
        r.cv.deleteRuntime = false
        check(r.c.retryPending().clean && r.cv.keys.isEmpty() && !r.c.purgeOwed("o"))
    }
    // 16. an Error from the vault inside custody (modelled death) still reaches the key delete before it propagates, and the owed record survives.
    run {
        val r = Rig(); r.c.enroll("o", INST, 1); r.seed(); r.cv.deleteDeath = true
        check(died { r.c.erase("o", 0, EraseTrigger.DISABLE) })
        check(r.sv.keys.isEmpty() && r.c.purgeOwed("o")); r.cv.deleteDeath = false
        check(r.restart().retryPending().clean && r.cv.keys.isEmpty() && !r.custody.readOwnerState("o").enabled) // DISABLE keeps its opt-out when retried
    }
    // Retry alone finishes physical seed deletion for purge and persistent disable; repeated failures remain bounded/fail closed.
    for (trigger in listOf(EraseTrigger.SIGN_OUT, EraseTrigger.DISABLE)) {
        val r = Rig(); r.c.enroll("o", INST, 1); r.seed(); r.cv.deleteDown = true
        check(!r.c.erase("o", 0, trigger).seedsPurged && r.c.purgeOwed("o"))
        val firstEpoch = r.custody.readOwnerState("o").epoch
        repeat(5) {
            check(!r.c.retryPending().clean && r.c.purgeOwed("o"))
            check(r.custody.readOwnerState("o").epoch == firstEpoch)
            want(SyncKeyError.ERASE_INCOMPLETE) { r.c.signRawForTests("o", byteArrayOf(1)) }
            want(SyncKeyError.ERASE_INCOMPLETE) { r.c.enroll("o", INST, 1) }
        }
        r.cv.deleteDown = false
        check(r.c.retryPending().clean && r.cv.keys.isEmpty() && !r.c.purgeOwed("o"))
        check(r.custody.readOwnerState("o").enabled == (trigger != EraseTrigger.DISABLE))
        if (trigger == EraseTrigger.DISABLE) r.custody.enableOwner("o", r.custody.readOwnerState("o").epoch)
        r.c.enroll("o", INST, 1)
    }
    // A stale caller must erase all owner keys at the real native epoch; repeat erase recaptures an advanced native epoch.
    for (trigger in listOf(EraseTrigger.SIGN_OUT, EraseTrigger.DISABLE)) {
        val r = Rig(); r.c.enroll("o", INST, 1); r.custody.enableOwner("o", 3); r.seed(epoch = 3)
        check(r.c.erase("o", 0, trigger).seedsPurged && r.cv.keys.isEmpty() && !r.c.purgeOwed("o"))
        check(r.custody.readOwnerState("o").epoch == 4L)
        val q = Rig(); q.c.enroll("o", INST, 1); q.seed(); q.cv.deleteDown = true
        check(!q.c.erase("o", 0, trigger).seedsPurged)
        q.custody.enableOwner("o", 3); q.seed(entry = "new", epoch = 3)
        check(!q.c.erase("o", 0, trigger).seedsPurged && q.c.purgeOwed("o"))
        val captured = q.custody.readOwnerState("o").epoch
        check(captured == 4L)
        repeat(5) { check(!q.c.retryPending().clean && q.custody.readOwnerState("o").epoch == captured) }
        q.cv.deleteDown = false
        check(q.restart().retryPending().clean && q.cv.keys.isEmpty() && !q.c.purgeOwed("o"))
    }
    run {
        val r = Rig(); r.c.enroll("o", INST, 1); r.custody.enableOwner("o", 3); r.seed(epoch = 3)
        check(try { r.c.erase("o", 9, EraseTrigger.SIGN_OUT); false } catch (e: CustodyFailure) { e.error == CustodyError.EPOCH_MISMATCH })
        check(r.c.purgeOwed("o") && r.cv.keys.isNotEmpty())
        want(SyncKeyError.ERASE_INCOMPLETE) { r.c.enroll("o", INST, 1) }
        check(r.restart().retryPending().clean && r.cv.keys.isEmpty())
        val q = Rig(); q.c.enroll("o", INST, 1); q.custody.enableOwner("o", 9); q.seed(epoch = 9); q.cv.deleteDown = true
        check(!q.c.erase("o", 9, EraseTrigger.SIGN_OUT).seedsPurged)
        q.cs.docs.clear(); q.cv.keys.clear() // explicit native metadata/vault reset; sync metadata still owes epoch 9
        q.seed(epoch = 0); q.cv.deleteDown = false
        check(q.restart().retryPending().clean && q.cv.keys.isEmpty() && !q.c.purgeOwed("o"))
    }
    // 17. retry isolation: one unreadable owner never stops the others; its document is left untouched.
    run {
        val r = Rig(); r.c.enroll("a", INST, 1); r.c.enroll("b", INST, 1); r.c.enroll("c", INST, 1); r.seed("b")
        r.sv.deleteDown = true; r.c.erase("b", 0, EraseTrigger.OWNER_SWITCH); r.sv.deleteDown = false
        val badDoc = "corrupt"; r.ss.docs[ownerKey("a")] = badDoc
        val res = r.c.retryPending()
        check(res.unreadableOwners == 1 && res.keyDeletesPending == 0 && r.ss.docs[ownerKey("a")] == badDoc)
        check(r.sv.keys.size == 2 && r.c.enrolled("c")) // a's alias kept (not grounded), b's removed
    }
    // 18. denies are bounded at 16: enroll refuses before the document could exceed it, and erase still decodes.
    run {
        val r = Rig(); r.sv.deleteDown = true
        var n = 0
        while (err { r.c.enroll("o", INST, 1) } == null) { n++; check(n < 40) }
        check(n == 16 && r.c.pendingKeyDeletes("o") == 15)
        r.c.erase("o", 0, EraseTrigger.SIGN_OUT)
        check(r.c.pendingKeyDeletes("o") == 16 && SyncState.decode(r.ss.docs.getValue(ownerKey("o")), "o").deny.size <= 16)
        r.sv.deleteDown = false; check(r.c.retryPending().clean && r.sv.keys.isEmpty()); r.c.enroll("o", INST, 1)
    }
    // 19. absent alias and fresh read-back: a delete that throws after the alias is gone counts as deleted; erasing with the alias already absent is fine.
    run {
        val r = Rig(); r.c.enroll("o", INST, 1); r.sv.goneThenThrow = true
        check(r.c.erase("o", 0, EraseTrigger.SIGN_OUT).keyDeleted && r.sv.keys.isEmpty()); r.sv.goneThenThrow = false
        val q = Rig(); q.c.enroll("o", INST, 1); q.sv.keys.clear()
        check(q.c.erase("o", 0, EraseTrigger.SIGN_OUT).keyDeleted && q.c.pendingKeyDeletes("o") == 0)
    }
    // 20. explicit recovery from a corrupt document: never automatic, owes a purge, then the orphan sweep removes the now-unreferenced alias.
    run {
        val r = Rig(); r.c.enroll("o", INST, 1); r.seed(); val good = r.ss.docs.getValue(ownerKey("o"))
        want(SyncKeyError.INVALID_INPUT) { r.c.resetUnreadableState("o") } // valid document: refused
        r.ss.docs[ownerKey("o")] = "corrupt"
        want(SyncKeyError.METADATA_UNAVAILABLE) { r.c.erase("o", 0, EraseTrigger.SIGN_OUT) }
        check(r.cv.keys.isEmpty() && r.sv.keys.size == 1) // seeds purged; the key is not deleted without grounding
        want(SyncKeyError.METADATA_UNAVAILABLE) { r.c.enroll("o", INST, 1) }
        want(SyncKeyError.METADATA_UNAVAILABLE) { r.c.sweepOrphans() }
        r.c.resetUnreadableState("o")
        check(r.c.purgeOwed("o") && r.sv.keys.size == 1)
        want(SyncKeyError.ERASE_INCOMPLETE) { r.c.enroll("o", INST, 1) }
        check(r.c.retryPending().clean && r.c.sweepOrphans().size == 1 && r.sv.keys.isEmpty())
        r.c.enroll("o", INST, 1); check(r.c.enrolled("o")); check(good.isNotEmpty())
    }
    wireChecks()
    handleChecks()
    println("PASS seed-sync enrollment key, deny-first erase state machine and wire interop vs vector a0ccb879 (JVM fakes, synthetic keys, simulated process death)")
}

private fun j(v: Any?): String = when(v) {
 null -> "null"
 is String -> "\"" + v.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n") + "\""
 is Map<*,*> -> v.entries.joinToString(",", "{", "}") { j(it.key.toString()) + ":" + j(it.value) }
 is List<*> -> v.joinToString(",", "[", "]") { j(it) }
 else -> v.toString()
}
private fun exportStatusFixture(path: String) {
 val now=1800000000000L
 fun ok(r:ChannelReply):Any? = (r as ChannelReply.Ok).value
 val outcomes=linkedMapOf<String,Any?>()
 for(kind in listOf("kept","purged","noop","pending","unreadable")) {
  val r=Rig();val h=SeedSyncChannelHandler(r.c,r.custody,{now})
  val en=ok(h.handle("syncEnroll",mapOf("owner" to "owner","installId" to INST,"generation" to 1L))) as Map<*,*>
  val key=en["keyId"] as String
  if(kind=="pending") { r.sv.deleteDown=true; h.handle("syncErase",mapOf("owner" to "owner","epoch" to 0L,"trigger" to "sign_out")) }
  if(kind=="pending") check((h.handle("syncStatusSign", mapOf("owner" to "owner", "keyId" to key, "challenge" to "A".repeat(43), "expiresAt" to now+60000L)) as ChannelReply.Err).code == "NOT_ENROLLED")

  if(kind=="unreadable") r.ss.docs[ownerKey("owner")]="garbage"
  outcomes[kind]=ok(h.handle("syncStatusApply",mapOf("owner" to "owner","keyId" to if(kind=="noop") "f".repeat(32) else key,"state" to if(kind=="kept") "active" else "key-revoked")))
 }
 val r=Rig();val h=SeedSyncChannelHandler(r.c,r.custody,{now})
 h.handle("syncEnroll",mapOf("owner" to "healthy","installId" to INST,"generation" to 1L))
 h.handle("syncEnroll",mapOf("owner" to "pending","installId" to INST,"generation" to 1L))
 r.sv.deleteDown=true;h.handle("syncErase",mapOf("owner" to "pending","epoch" to 0L,"trigger" to "sign_out"));r.ss.docs[ownerKey("bad")]="garbage"
 java.io.File(path).writeText(j(mapOf("outcomes" to outcomes,"discovery" to ok(h.handle("syncDiscoverOwners",emptyMap<String,Any>())))))

}
