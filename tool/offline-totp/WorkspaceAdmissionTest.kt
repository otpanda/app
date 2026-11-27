package org.otpanda.totp

// JVM logic tests for WorkspaceAdmissionCore and its channel against in-memory fakes. NOT device file-system, durability, backup or uninstall evidence.
private fun chk(c: Boolean, m: String = "check failed") { if (!c) throw IllegalStateException(m) }
private class Docs : AdmissionDocs {
    var text: String? = null; var readDown = false; var writeDown = false; var writes = 0
    override fun read(): String? { if (readDown) throw java.io.IOException("down"); return text }
    override fun write(text: String) { if (writeDown) throw java.io.IOException("down"); this.text = text; writes++ }
}
private class Canary : InstallIdStore {
    var id: String? = null; var readDown = false; var createDown = false; var creates = 0
    override fun read(): String? { if (readDown) throw InstallIdFailure(InstallIdFailure.Kind.UNREADABLE); return id }
    override fun createIfAbsent(candidate: String): Pair<String, Boolean> {
        if (createDown) throw InstallIdFailure(InstallIdFailure.Kind.UNAVAILABLE)
        id?.let { return it to false }; id = candidate; creates++; return candidate to true
    }
}
private class Install : InstallIdStore {
    var id: String? = "I".repeat(22); var down = false
    override fun read(): String? { if (down) throw InstallIdFailure(InstallIdFailure.Kind.UNREADABLE); return id }
    override fun createIfAbsent(candidate: String): Pair<String, Boolean> = throw UnsupportedOperationException()
}
private class Rig {
    val docs = Docs(); val canary = Canary(); val install = Install()
    val owners = HashMap<String, CustodyOwnerState>(); var ownersDown = false; var prepareDown = false; var prepared = 0; var n = 0
    fun core() = WorkspaceAdmissionCore(docs, canary, install,
        { o -> if (ownersDown) throw CustodyFailure(CustodyError.METADATA_UNAVAILABLE); owners[o] ?: CustodyOwnerState(0, true) },
        { k -> "/data/noBackup/otpanda-workspace-v1/$k.db" },
        { "C${(++n).toString().padStart(21, '0')}" },
        { if (prepareDown) throw java.io.IOException("down"); prepared++ })
}
private fun err(w: () -> Any?): AdmissionError? = try { w(); null } catch (e: AdmissionFailure) { e.error }
private fun want(e: AdmissionError, w: () -> Any?) { val got = err(w); chk(got == e, "expected $e got $got") }
private fun unavailable(c: WorkspaceAdmissionCore, e: AdmissionError) { val r = c.discover(); chk(r is DiscoverResult.Unavailable && r.reason == e, "discover expected unavailable $e got $r") }

fun main() {
    val A = "owner-a"; val B = "owner-b"
    // 1. empty install: absent, nothing created by a read
    run { val r = Rig(); val c = r.core(); chk(c.discover() === DiscoverResult.Absent); chk(r.docs.text == null && r.canary.id == null && r.docs.writes == 0) }
    // 2. first admission, pending is not cold-ready, confirm makes it ready, ready never creates again
    run {
        val r = Rig(); val c = r.core(); val a = c.admit(A, 0)
        chk(a.createAllowed && r.canary.id != null && r.docs.text!!.contains("canary ${r.canary.id}") && r.prepared == 1)
        unavailable(c, AdmissionError.NOT_ADMITTED)
        chk(!c.admit(A, 0).createAllowed && c.admit(A, 0).scope == a.scope, "armed pending retry keeps the same scope and NEVER regrants create")
        val s = c.confirm(A, 0); chk(s == a.scope)
        val d = c.discover(); chk(d is DiscoverResult.Ready && d.scope == s)
        chk(!c.admit(A, 0).createAllowed, "ready never gets create permission again")
        chk(c.confirm(A, 0) == s, "confirm idempotent")
        chk(s.namespace.length <= 64 && Regex("[A-Za-z0-9_-]+").matches(s.namespace) && s.path.endsWith(".db") && !s.path.contains(A) && !s.namespace.contains(A))
        chk(s == c.admit(A, 0).scope && s.install == "I".repeat(22) && s.epoch == 0L)
    }
    // 3. crash after the document, before the canary: the next admit completes the SAME scope
    run {
        val r = Rig(); val c = r.core(); r.canary.createDown = true
        want(AdmissionError.UNAVAILABLE) { c.admit(A, 0) }
        chk(r.docs.text != null && r.canary.id == null, "document durable, canary not")
        unavailable(c, AdmissionError.AMBIGUOUS)
        r.canary.createDown = false
        val a = c.admit(A, 0); chk(a.createAllowed && r.canary.id != null && r.docs.text!!.contains("canary ${r.canary.id}"))
        chk(c.confirm(A, 0) == a.scope)
    }
    // 4. document write failure on first admission: nothing changes, retry works
    run { val r = Rig(); val c = r.core(); r.docs.writeDown = true; want(AdmissionError.UNAVAILABLE) { c.admit(A, 0) }; chk(r.docs.text == null && r.canary.id == null); r.docs.writeDown = false; chk(c.admit(A, 0).createAllowed) }
    // 5. canary without a document is never a fresh install
    run {
        val r = Rig(); val c = r.core(); c.admit(A, 0); c.confirm(A, 0); r.docs.text = null
        unavailable(c, AdmissionError.AMBIGUOUS); want(AdmissionError.AMBIGUOUS) { c.admit(A, 0) }; chk(r.docs.text == null, "nothing re-created")
        val r2 = Rig(); r2.canary.id = "X".repeat(30); want(AdmissionError.AMBIGUOUS) { r2.core().admit(A, 0) }
    }
    // 6. ready document with a missing or different canary: ambiguous, never repaired
    run {
        val r = Rig(); val c = r.core(); c.admit(A, 0); c.confirm(A, 0); val before = r.docs.text; val id = r.canary.id
        r.canary.id = null; unavailable(c, AdmissionError.AMBIGUOUS); want(AdmissionError.AMBIGUOUS) { c.admit(A, 0) }; chk(r.canary.id == null && r.docs.text == before)
        r.canary.id = "Z".repeat(43); unavailable(c, AdmissionError.AMBIGUOUS); want(AdmissionError.AMBIGUOUS) { c.admit(A, 0) }; chk(r.canary.id == "Z".repeat(43))
        r.canary.id = id; chk(c.discover() is DiscoverResult.Ready)
    }
    // 7. a lost canary after the first admission completed is ambiguous (pending or ready); only a crash before the canary was ever created is completed (test 19)
    run {
        val r = Rig(); val c = r.core(); c.admit(A, 0); r.canary.id = null
        want(AdmissionError.AMBIGUOUS) { c.admit(A, 0) }; r.canary.id = r.docs.text!!.lines().first { it.startsWith("canary") }.substringAfter(' ').trim()
        c.confirm(A, 0); c.invalidate(A); c.admit(B, 0); r.canary.id = null
        want(AdmissionError.AMBIGUOUS) { c.admit(B, 0) }
    }
    // 8. custody checks: opt-out, epoch change, unreadable custody are never "absent"
    run {
        val r = Rig(); val c = r.core(); c.admit(A, 0); c.confirm(A, 0)
        r.owners[A] = CustodyOwnerState(0, false); unavailable(c, AdmissionError.DISABLED); want(AdmissionError.DISABLED) { c.admit(A, 0) }
        r.owners[A] = CustodyOwnerState(1, true); unavailable(c, AdmissionError.EPOCH_MISMATCH); want(AdmissionError.EPOCH_MISMATCH) { c.admit(A, 0) }; want(AdmissionError.EPOCH_MISMATCH) { c.admit(A, 1) }
        want(AdmissionError.EPOCH_MISMATCH) { c.confirm(A, 0) }
        r.owners[A] = CustodyOwnerState(0, true); r.ownersDown = true; unavailable(c, AdmissionError.UNAVAILABLE); want(AdmissionError.UNAVAILABLE) { c.admit(A, 0) }
        r.ownersDown = false; chk(c.discover() is DiscoverResult.Ready)
        val r2 = Rig(); r2.owners[A] = CustodyOwnerState(2, true); want(AdmissionError.EPOCH_MISMATCH) { r2.core().admit(A, 0) }; chk(r2.docs.text == null && r2.canary.id == null, "refused admit creates nothing")
        r2.owners[A] = CustodyOwnerState(2, false); want(AdmissionError.DISABLED) { r2.core().admit(A, 2) }; chk(r2.docs.text == null)
    }
    // 9. install id: missing, changed and unreadable are distinct and never absent
    run {
        val r = Rig(); r.install.id = null; want(AdmissionError.INSTALL_MISSING) { r.core().admit(A, 0) }; chk(r.docs.text == null && r.canary.id == null)
        r.install.id = "I".repeat(22); val c = r.core(); c.admit(A, 0); c.confirm(A, 0)
        r.install.id = "J".repeat(22); unavailable(c, AdmissionError.INSTALL_CHANGED); want(AdmissionError.INSTALL_CHANGED) { c.admit(A, 0) }
        r.install.id = null; unavailable(c, AdmissionError.INSTALL_MISSING)
        r.install.id = "I".repeat(22); r.install.down = true; unavailable(c, AdmissionError.UNAVAILABLE); want(AdmissionError.UNAVAILABLE) { c.admit(A, 0) }
    }
    // 10. invalidate: only the active owner's cold selection; scope, canary and a resume survive
    run {
        val r = Rig(); val c = r.core(); chk(!c.invalidate(A)); val a = c.admit(A, 0); c.confirm(A, 0); val canary = r.canary.id
        chk(!c.invalidate(B) && c.discover() is DiscoverResult.Ready, "another owner cannot clear the selection")
        chk(c.invalidate(A)); chk(c.discover() === DiscoverResult.Absent); chk(!c.invalidate(A))
        chk(r.canary.id == canary && r.docs.text!!.contains("scope ${workspaceScopeKey(A, a.scope.install)}"), "scope and canary kept")
        val again = c.admit(A, 0); chk(again.scope == a.scope && !again.createAllowed, "re-admission resumes the SAME ready scope without create permission")
        chk(c.discover() is DiscoverResult.Ready)
        want(AdmissionError.INVALID_INPUT) { c.invalidate("") }
    }
    // 11. owner switch: no guessing among owners, distinct scopes, nothing deleted
    run {
        val r = Rig(); val c = r.core(); val a = c.admit(A, 0); c.confirm(A, 0)
        want(AdmissionError.OWNER_CONFLICT) { c.admit(B, 0) }
        chk(c.invalidate(A)); val b = c.admit(B, 0); chk(b.createAllowed && b.scope.namespace != a.scope.namespace && b.scope.path != a.scope.path)
        unavailable(c, AdmissionError.NOT_ADMITTED); c.confirm(B, 0)
        val d = c.discover(); chk(d is DiscoverResult.Ready && d.scope.owner == B)
        want(AdmissionError.NOT_ADMITTED) { c.confirm(A, 0) }
        chk(c.invalidate(B)); val back = c.admit(A, 0); chk(back.scope == a.scope && !back.createAllowed)
    }
    // 12. corrupt or hand-edited documents fail closed and are left untouched
    run {
        val r = Rig(); val c = r.core(); val a = c.admit(A, 0); c.confirm(A, 0); val good = r.docs.text!!
        val key = workspaceScopeKey(A, a.scope.install)
        for (bad in listOf("", "garbage", good.replace("otpanda-workspace-admission-v1", "v2"), good.replace("active $key", "active ${"0".repeat(64)}"), good + good.lines().last { it.startsWith("scope ") } + "\n",
            good.replace("ready", "maybe"), good.replace(" 0 ready", " -1 ready"), good.replace(key, "1".repeat(64)), good + "extra line\n")) {
            r.docs.text = bad; unavailable(c, AdmissionError.CORRUPT); want(AdmissionError.CORRUPT) { c.admit(A, 0) }; want(AdmissionError.CORRUPT) { c.confirm(A, 0) }; want(AdmissionError.CORRUPT) { c.invalidate(A) }; chk(r.docs.text == bad, "bad document untouched")
        }
    }
    // 13. unreadable stores are unavailable, never absent or fresh
    run {
        val r = Rig(); val c = r.core(); r.docs.readDown = true; unavailable(c, AdmissionError.UNAVAILABLE); want(AdmissionError.UNAVAILABLE) { c.admit(A, 0) }
        r.docs.readDown = false; r.canary.readDown = true; unavailable(c, AdmissionError.UNAVAILABLE); want(AdmissionError.UNAVAILABLE) { c.admit(A, 0) }; chk(r.docs.text == null)
        r.canary.readDown = false; c.admit(A, 0); c.confirm(A, 0); r.canary.readDown = true; unavailable(c, AdmissionError.UNAVAILABLE); r.canary.readDown = false
        r.docs.writeDown = true; want(AdmissionError.UNAVAILABLE) { c.invalidate(A) }; chk(c.discover() is DiscoverResult.Ready, "failed invalidate leaves the selection; caller must retry")
        val r2 = Rig(); r2.prepareDown = true; want(AdmissionError.UNAVAILABLE) { r2.core().admit(A, 0) }
    }
    // 14. pending retry across a failed confirm write: still the same scope with create permission
    run { val r = Rig(); val c = r.core(); c.admit(A, 0); r.docs.writeDown = true; want(AdmissionError.UNAVAILABLE) { c.confirm(A, 0) }; r.docs.writeDown = false; chk(!c.admit(A, 0).createAllowed); c.confirm(A, 0); chk(!c.admit(A, 0).createAllowed) }
    // 15. confirm without admit, invalid inputs, ledger bound
    run {
        val r = Rig(); val c = r.core(); want(AdmissionError.NOT_ADMITTED) { c.confirm(A, 0) }; want(AdmissionError.INVALID_INPUT) { c.admit("", 0) }; want(AdmissionError.INVALID_INPUT) { c.admit("a\u0000b", 0) }
        want(AdmissionError.INVALID_INPUT) { c.admit(A, -1) }; want(AdmissionError.INVALID_INPUT) { c.admit(A, CUSTODY_MAX_SAFE_INT) }; want(AdmissionError.INVALID_INPUT) { c.admit("x".repeat(129), 0) }
        for (i in 0 until 32) { c.admit("o$i", 0); c.confirm("o$i", 0); c.invalidate("o$i") }
        want(AdmissionError.LEDGER_FULL) { c.admit("one-more", 0) }; chk(c.admit("o3", 0).scope.owner == "o3" && !c.admit("o3", 0).createAllowed, "known owners still resume at the bound")
    }
    // 16. derivation is stable and hash-only
    run {
        val k1 = workspaceScopeKey(A, "I".repeat(22)); chk(k1 == workspaceScopeKey(A, "I".repeat(22)) && k1 != workspaceScopeKey(B, "I".repeat(22)) && k1 != workspaceScopeKey(A, "J".repeat(22)))
        chk(workspaceNamespace(k1).length == 51 && workspaceNamespace(k1) == "ws-" + k1.take(48))
        chk(workspaceScopeKey("ab", "I".repeat(22)) != workspaceScopeKey("a", "bI".repeat(11)), "length-prefixed, no concatenation collision")
    }
    // 17. concurrent admissions on one core serialize
    run {
        val r = Rig(); val c = r.core(); val results = java.util.concurrent.ConcurrentLinkedQueue<Any>()
        val ts = (1..8).map { Thread { try { results.add(c.admit(A, 0).scope) } catch (e: AdmissionFailure) { results.add(e.error) } }.also { it.start() } }; ts.forEach { it.join() }
        chk(results.toSet().size == 1 && results.first() is WorkspaceScope && r.canary.creates == 1 && r.docs.writes == 2, "pending write plus one arm write and one canary for 8 callers")
    }
    // 18. channel wire contract
    run {
        val r = Rig(); val h = WorkspaceAdmissionChannelHandler(r.core())
        fun ok(m: String, a: Any?) = (h.handle(m, a) as ChannelReply.Ok).value as Map<*, *>
        fun bad(m: String, a: Any?) { val x = h.handle(m, a); chk(x is ChannelReply.Err && x.code == "INVALID_INPUT", "$m $a -> $x") }
        val abs = ok("discover", emptyMap<String, Any>()); chk(abs == mapOf("status" to "absent", "reason" to null, "scope" to null, "createAllowed" to false), "$abs")
        chk(ok("discover", null)["status"] == "absent")
        bad("discover", mapOf("x" to 1)); bad("admit", null); bad("admit", mapOf("owner" to A)); bad("admit", mapOf("owner" to A, "epoch" to 0.0)); bad("admit", mapOf("owner" to A, "epoch" to "0"))
        bad("admit", mapOf("owner" to 5, "epoch" to 0L)); bad("admit", mapOf("owner" to A, "epoch" to 0, "path" to "/x")); bad("invalidate", mapOf("owner" to A, "x" to 1)); bad("confirm", emptyMap<String, Any>())
        chk(h.handle("nope", emptyMap<String, Any>()) === ChannelReply.NotImplemented)
        val ad = ok("admit", mapOf("owner" to A, "epoch" to 0)); val sc = ad["scope"] as Map<*, *>
        chk(ad["createAllowed"] == true && sc.keys == setOf("owner", "install", "epoch", "namespace", "path") && sc["epoch"] is Long && sc["owner"] == A, "$ad")
        chk(ok("discover", emptyMap<String, Any>()).let { it["status"] == "unavailable" && it["reason"] == "NOT_ADMITTED" && it["createAllowed"] == false })
        chk(ok("confirm", mapOf("owner" to A, "epoch" to 0L))["scope"] == sc)
        val rd = ok("discover", emptyMap<String, Any>()); chk(rd["status"] == "ready" && rd["scope"] == sc && rd["createAllowed"] == false && rd["reason"] == null)
        r.owners[A] = CustodyOwnerState(0, false); chk(ok("discover", emptyMap<String, Any>())["reason"] == "DISABLED")
        val e = h.handle("admit", mapOf("owner" to A, "epoch" to 0L)); chk(e is ChannelReply.Err && e.code == "DISABLED")
        r.owners.clear(); chk(ok("invalidate", mapOf("owner" to A)) == mapOf("invalidated" to true)); chk(ok("invalidate", mapOf("owner" to A)) == mapOf("invalidated" to false))
        chk(!h.toString().contains(A))
    }
    // 19. armed marker: canary deleted after a completed first admit is ambiguous even while pending; a crash between document and canary is still completed
    run {
        val r = Rig(); r.canary.createDown = true; var c = r.core()
        want(AdmissionError.UNAVAILABLE) { c.admit(A, 0) }; chk(r.docs.text != null && r.canary.id == null)
        r.canary.createDown = false; chk(c.admit(A, 0).createAllowed); chk(r.canary.id != null)
        r.canary.id = null
        want(AdmissionError.AMBIGUOUS) { c.admit(A, 0) }; want(AdmissionError.AMBIGUOUS) { c.confirm(A, 0) }; chk(r.canary.id == null)
    }
    // 20. document presence: definite absence versus unreadable, directory, leftover, non-directory parent
    run {
        val root = java.nio.file.Files.createTempDirectory("adm").toFile()
        val d = java.io.File(root, "d")
        chk(admissionDocPresence(d) == DocPresence.ABSENT)
        d.mkdir(); chk(admissionDocPresence(d) == DocPresence.ABSENT)
        java.io.File(d, "admission").mkdir(); chk(admissionDocPresence(d) != DocPresence.ABSENT)
        java.io.File(d, "admission").delete(); java.io.File(d, "admission").writeText("x"); chk(admissionDocPresence(d) == DocPresence.PRESENT)
        java.io.File(d, "admission").delete(); java.io.File(d, "admission.bak").writeText("x"); chk(admissionDocPresence(d) == DocPresence.PRESENT)
        val f = java.io.File(root, "file"); f.writeText("x"); chk(admissionDocPresence(f) == DocPresence.UNKNOWN)
        val u = java.io.File(root, "u"); u.mkdir(); java.io.File(u, "admission").writeText("x")
        if (u.setReadable(false) && u.setExecutable(false) && !java.io.File(u, "admission").exists()) chk(admissionDocPresence(u) != DocPresence.ABSENT, "unsearchable dir must not be absence")
        u.setReadable(true); u.setExecutable(true)
        root.deleteRecursively()
    }
    // 21. create permission is issued exactly once per scope: second owner once, never again before confirm; a crash before any reply is the only re-issue
    run {
        val r = Rig(); val c = r.core(); c.admit(A, 0); c.confirm(A, 0); c.invalidate(A)
        chk(c.admit(B, 0).createAllowed); chk(!c.admit(B, 0).createAllowed); chk(!c.admit(B, 0).createAllowed); chk(c.discover().let { it is DiscoverResult.Unavailable && it.reason == AdmissionError.NOT_ADMITTED })
        chk(!r.docs.text!!.lines().any { it.startsWith("scope") && it.endsWith(" pending") })
        val r2 = Rig(); val c2 = r2.core(); r2.canary.createDown = true; want(AdmissionError.UNAVAILABLE) { c2.admit(A, 0) }; r2.canary.createDown = false
        chk(c2.admit(A, 0).createAllowed); chk(!c2.admit(A, 0).createAllowed)
    }
    println("PASS workspace admission core and channel tests (JVM fakes; not device file-system evidence)")
}
