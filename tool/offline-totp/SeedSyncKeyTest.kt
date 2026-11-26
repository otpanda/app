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

// ---- wire interop against the API author's synthetic vector (seed-sync-vector-7e2e6f9c.json; SYNTHETIC keys, values copied verbatim) ----
private val VJ = "Og1mLdUNFJMN8kfj2LcxyVf8_r0n7YT9z-NNtV5RUUo"; private val VY = "_0JaZpKEEe0DnvGvW_VwoMtxMQz9ihVPcecxoDr9rzs"
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
        Triple(SyncPurpose.ENROLL, mapOf("ownerId" to "owner", "keyId" to "key", "installId" to "I".repeat(22), "generation" to 1L, "challenge" to ch, "actionDigest" to "b".repeat(64), "expiresAt" to 1800000120000L),
            Pair("WyJvdHBhbmRhLXNlZWQtc3luYy12MSIsInNlZWQtc3luYy1lbnJvbGwiLCJvd25lciIsImtleSIsIklJSUlJSUlJSUlJSUlJSUlJSUlJSUkiLDEsIkFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUEiLCJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiIiwxODAwMDAwMTIwMDAwXQ==", "qJoksY0hYMtZgSCE3cekerJu86tNWVhtyfhqNMwUr11G_P4H9-1sesq77tByw5BD4mfbo7lCei5oysLWrLMe5w")),
        Triple(SyncPurpose.SNAPSHOT, mapOf("ownerId" to "owner", "keyId" to "key", "deviceId" to "device", "generation" to 1L, "epoch" to 7L, "challenge" to ch, "expiresAt" to 1800000120000L),
            Pair("WyJvdHBhbmRhLXNlZWQtc3luYy12MSIsInNlZWQtc3luYy1zbmFwc2hvdCIsIm93bmVyIiwia2V5IiwiZGV2aWNlIiwxLDcsIkFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUEiLDE4MDAwMDAxMjAwMDBd", "2hPWoSecD_pmTZrM6wO2PJ8Ifh5M13KfYQpb3C7yYwCRgNVSM673ag3d8QXYg2EaasagyksCmiCy0xbYOigF9w")),
        Triple(SyncPurpose.REVOKE, mapOf("ownerId" to "owner", "keyId" to "key", "deviceId" to "device", "generation" to 1L, "challenge" to ch, "expiresAt" to 1800000120000L),
            Pair("WyJvdHBhbmRhLXNlZWQtc3luYy12MSIsInNlZWQtc3luYy1yZXZva2UiLCJvd25lciIsImtleSIsImRldmljZSIsMSwiQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQSIsMTgwMDAwMDEyMDAwMF0=", "FOsA5g0tdvZ290ot7dOAFxl1vx154pKqjag-LO6_aOAMtQN6fOyRBY5ED1uA7BRD4FerIVXf775MnT6Cwub6Yg")),
        Triple(SyncPurpose.BATCH, mapOf("ownerId" to "owner", "keyId" to "key", "deviceId" to "device", "generation" to 1L, "epoch" to 7L, "challenge" to ch, "ephemeralDigest" to "c".repeat(64), "entriesDigest" to "d".repeat(64), "expiresAt" to 1800000120000L),
            Pair("WyJvdHBhbmRhLXNlZWQtc3luYy12MSIsInNlZWQtc3luYy1iYXRjaCIsIm93bmVyIiwia2V5IiwiZGV2aWNlIiwxLDcsIkFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUEiLCJjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjIiwiZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZCIsMTgwMDAwMDEyMDAwMF0=", "pZ-sCrQNGBYkwuJp2AUNhhs9enELdEUDWmQPRI7rDf86B_uzuPD7H3MMciAnhwtmvnOa0OVNTVKWDz0KRSl8gA")))
    run {
        val r = Rig(); r.c.enroll("o", INST, 1)
        val key = ownerKey("o"); val doc = r.ss.docs.getValue(key)
        r.ss.docs[key] = doc.lines().joinToString("\n") { line -> if (line.startsWith("active ")) line.split(' ').take(3).joinToString(" ") else line }
        want(SyncKeyError.METADATA_UNAVAILABLE) { r.c.enrolled("o") }
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

    // W10. revoke purpose (online own-key sign-out/disable): no epoch field, signed by the dedicated key, cross-purpose use fails (covered in W1 over four purposes).
    run {
        val r = Rig(); val en = r.c.enroll("o", INST, 2); val now = 1_800_000_000_000L; val ch2 = "C".repeat(43)
        val f = mapOf("deviceId" to "device", "generation" to 2L, "challenge" to ch2, "expiresAt" to now + 60_000)
        val sig = SeedSyncWire.signProof(r.c, "o", SyncPurpose.REVOKE, f, now)
        val pub = KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(BigInteger(1, en.publicKey.copyOfRange(1, 33)), BigInteger(1, en.publicKey.copyOfRange(33, 65))), SeedSyncWire.jcaParams()))
        check(verifyServerSig(SeedSyncWire.proofMessage(SyncPurpose.REVOKE, f + mapOf("ownerId" to "o", "keyId" to en.keyId)), sig, pub))
        check(!verifyServerSig(SeedSyncWire.proofMessage(SyncPurpose.SNAPSHOT, f + mapOf("ownerId" to "o", "keyId" to en.keyId, "epoch" to 0L)), sig, pub))
        check(wireErr { SeedSyncWire.signProof(r.c, "o", SyncPurpose.REVOKE, f + ("epoch" to 0L), now) } == "fields")
        check(SyncPurpose.values().map { it.wire }.toSet().size == 4)
    }

}

private fun owners(r: Rig) = r.ss.docs.keys.toList()

fun main() {
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
    println("PASS seed-sync enrollment key, deny-first erase state machine and wire interop vs vector 7e2e6f9c (JVM fakes, synthetic keys, simulated process death)")
}
