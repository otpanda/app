package org.otpanda.totp

import java.security.MessageDigest

// Durable, native-owned admission of ONE encrypted offline workspace per install, independent of any server session. Pure JVM logic over three small
// stores (all injectable): the admission document, a create-only canary, and the existing install id and owner custody state. It never creates, opens or
// deletes the database or its wrapping key (Dart does, using the scope returned here), never stores a secret, and never logs. Not wired into the app.
//
// Model. A "scope" is (owner, install). Its namespace (wrapping-key name) and database file name are derived here, stable and hash-only, so Dart never supplies a
// path or a name. ONE document (`admission`) holds the canary id, the ledger of known scopes (pending|armed|ready; armed = canary was created, a missing canary is then ambiguous) and the ACTIVE pointer (a scope key or none), so every
// state change is one atomic replace. The canary is a separate create-only file whose value must equal the document's canary id.
//
// Create permission is one-shot: the call that durably arms a scope may return true.
// Every later admit is open-existing-only, even while pending. A crash after arm
// but before key/database creation strands pending bootstrap explicitly. It does
// not establish absence and never authorizes a replacement key or database.
// Before arm, an interrupted document/canary write may complete on authenticated
// retry. Cold discover only returns confirmed-ready scopes, never createAllowed.
// No operation here deletes anything. invalidate only sets the active pointer to none (the scope, canary, key and database stay; a re-admission resumes the SAME scope).
//
// UNVERIFIED: real file semantics on a device (see AndroidWorkspaceAdmissionStore), and rollback of the private directory by someone who can replace app files.

enum class AdmissionError {
    INVALID_INPUT, UNAVAILABLE, DISABLED, EPOCH_MISMATCH, INSTALL_MISSING, INSTALL_CHANGED, OWNER_CONFLICT, NOT_ADMITTED, CORRUPT, AMBIGUOUS, LEDGER_FULL,
}
/** Carries only the kind. */
class AdmissionFailure(val error: AdmissionError) : Exception(error.name)

/** Durable document store. read returns null ONLY for a definite absence; any other failure throws. write is an atomic replace that is durable when it returns. */
interface AdmissionDocs {
    fun read(): String?
    fun write(text: String)
}
/** The per-install workspace canary: create-only, durable. Backed by InstallIdFile on a device, so the same create-only machinery is reused. */
typealias AdmissionCanary = InstallIdStore

data class WorkspaceScope(val owner: String, val install: String, val epoch: Long, val namespace: String, val path: String)
sealed class DiscoverResult {
    data class Ready(val scope: WorkspaceScope) : DiscoverResult()
    object Absent : DiscoverResult()
    data class Unavailable(val reason: AdmissionError) : DiscoverResult()
}
data class Admitted(val scope: WorkspaceScope, val createAllowed: Boolean)

private const val DOC_HEADER = "otpanda-workspace-admission-v1"
private const val MAX_SCOPES = 32
private val hex64 = Regex("[0-9a-f]{64}")
private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
private fun b64(s: String) = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(s.toByteArray(Charsets.UTF_8))
private fun unb64(s: String) = String(java.util.Base64.getUrlDecoder().decode(s), Charsets.UTF_8)

/** Stable, hash-only scope key: SHA-256 over length-prefixed install and owner. The namespace (<= 64 chars, [A-Za-z0-9_-]) and the file name derive from it. */
fun workspaceScopeKey(owner: String, install: String): String {
    val d = MessageDigest.getInstance("SHA-256")
    fun field(s: String) { val b = s.toByteArray(Charsets.UTF_8); d.update(byteArrayOf((b.size ushr 24).toByte(), (b.size ushr 16).toByte(), (b.size ushr 8).toByte(), b.size.toByte())); d.update(b) }
    field("otpanda.workspace.scope.v1"); field(install); field(owner)
    return hex(d.digest())
}
fun workspaceNamespace(scopeKey: String) = "ws-" + scopeKey.substring(0, 48) // 51 chars

internal class LedgerScope(val key: String, val owner: String, val install: String, val epoch: Long, var ready: Boolean, var armed: Boolean = ready)
internal class AdmissionDoc(val canary: String, val scopes: MutableList<LedgerScope>, var active: String?) {
    fun encode(): String = buildString {
        append(DOC_HEADER).append('\n').append("canary ").append(canary).append('\n').append("active ").append(active ?: "none").append('\n')
        for (s in scopes) append("scope ").append(s.key).append(' ').append(b64(s.owner)).append(' ').append(s.install).append(' ').append(s.epoch).append(' ').append(if (s.ready) "ready" else if (s.armed) "armed" else "pending").append('\n')
    }
    companion object {
        fun decode(text: String): AdmissionDoc {
            val lines = text.split('\n').let { if (it.isNotEmpty() && it.last().isEmpty()) it.dropLast(1) else it }
            if (lines.size < 3 || lines[0] != DOC_HEADER) throw AdmissionFailure(AdmissionError.CORRUPT)
            if (!lines[1].startsWith("canary ") || !lines[2].startsWith("active ")) throw AdmissionFailure(AdmissionError.CORRUPT)
            val canary = lines[1].removePrefix("canary "); val activeText = lines[2].removePrefix("active ")
            if (!validInstallId(canary)) throw AdmissionFailure(AdmissionError.CORRUPT)
            val scopes = ArrayList<LedgerScope>()
            try {
                for (l in lines.drop(3)) {
                    val p = l.split(' ')
                    if (p.size != 6 || p[0] != "scope" || !hex64.matches(p[1]) || !validInstallId(p[3])) throw AdmissionFailure(AdmissionError.CORRUPT)
                    val owner = unb64(p[2]); val epoch = p[4].toLong()
                    if (!validCustodyId(owner) || epoch < 0 || epoch >= CUSTODY_MAX_SAFE_INT || p[5] !in setOf("ready", "armed", "pending")) throw AdmissionFailure(AdmissionError.CORRUPT)
                    if (workspaceScopeKey(owner, p[3]) != p[1] || scopes.any { it.key == p[1] }) throw AdmissionFailure(AdmissionError.CORRUPT)
                    scopes.add(LedgerScope(p[1], owner, p[3], epoch, p[5] == "ready", p[5] != "pending"))
                }
            } catch (e: AdmissionFailure) { throw e } catch (_: Exception) { throw AdmissionFailure(AdmissionError.CORRUPT) }
            val active = if (activeText == "none") null else activeText
            if (active != null && scopes.none { it.key == active }) throw AdmissionFailure(AdmissionError.CORRUPT)
            if (scopes.size > MAX_SCOPES) throw AdmissionFailure(AdmissionError.CORRUPT)
            return AdmissionDoc(canary, scopes, active)
        }
    }
}

class WorkspaceAdmissionCore(
    private val docs: AdmissionDocs,
    private val canary: AdmissionCanary,
    private val installIds: InstallIdStore,
    /** Owner custody state (epoch, enabled). Throws CustodyFailure when unreadable. */
    private val ownerState: (String) -> CustodyOwnerState,
    /** Native-owned database path for a scope key (noBackup, private). Dart never supplies it. */
    private val pathFor: (String) -> String,
    private val randomCanaryId: () -> String,
    /** Creates the private database directory and confirms it durable. Throws on failure. Called by admit only, before it returns a scope. */
    private val prepareStorage: () -> Unit = {},
) {
    private val lock = Any()
    private fun fail(e: AdmissionError): Nothing = throw AdmissionFailure(e)
    private fun scope(s: LedgerScope) = WorkspaceScope(s.owner, s.install, s.epoch, workspaceNamespace(s.key), pathFor(s.key))

    private fun loadDoc(): AdmissionDoc? = try { docs.read()?.let { AdmissionDoc.decode(it) } } catch (e: AdmissionFailure) { throw e } catch (_: Exception) { fail(AdmissionError.UNAVAILABLE) }
    private fun saveDoc(d: AdmissionDoc) { try { docs.write(d.encode()) } catch (_: Exception) { fail(AdmissionError.UNAVAILABLE) } }
    private fun readCanary(): String? = try { canary.read() } catch (_: Exception) { fail(AdmissionError.UNAVAILABLE) }
    private fun install(): String = try { installIds.read() } catch (_: Exception) { fail(AdmissionError.UNAVAILABLE) } ?: fail(AdmissionError.INSTALL_MISSING)
    private fun custody(owner: String): CustodyOwnerState = try { ownerState(owner) } catch (_: CustodyFailure) { fail(AdmissionError.UNAVAILABLE) } catch (_: Exception) { fail(AdmissionError.UNAVAILABLE) }
    private fun prepare() { try { prepareStorage() } catch (_: Exception) { fail(AdmissionError.UNAVAILABLE) } }
    private fun checkInput(owner: String, epoch: Long) { if (!validCustodyId(owner) || epoch < 0 || epoch >= CUSTODY_MAX_SAFE_INT) fail(AdmissionError.INVALID_INPUT) }
    private fun custodyOk(owner: String, epoch: Long) { val c = custody(owner); if (!c.enabled) fail(AdmissionError.DISABLED); if (c.epoch != epoch) fail(AdmissionError.EPOCH_MISMATCH) }

    /** The canary must exist and equal the document's id. A pending-only history (no scope was ever ready) may complete a missing canary from the document: nothing was bootstrapped yet,
     * or Dart will fail closed on an existing database it cannot open. Otherwise a missing or different canary is ambiguous. [mayComplete] is false for read-only calls. */
    private fun checkCanary(d: AdmissionDoc, mayComplete: Boolean) {
        val c = readCanary()
        when {
            c == d.canary -> {}
            c == null && mayComplete && d.scopes.none { it.armed } -> {
                val r = try { canary.createIfAbsent(d.canary) } catch (_: Exception) { fail(AdmissionError.UNAVAILABLE) }
                if (r.first != d.canary) fail(AdmissionError.AMBIGUOUS)
            }
            else -> fail(AdmissionError.AMBIGUOUS)
        }
    }

    /** Cold discovery: no mutation, no creation, no session. Ready only for the one ACTIVE, confirmed scope whose owner is not opted out and whose epoch and install still match. */
    fun discover(): DiscoverResult = synchronized(lock) {
        try {
            val d = loadDoc()
            if (d == null) {
                return if (readCanary() == null) DiscoverResult.Absent else DiscoverResult.Unavailable(AdmissionError.AMBIGUOUS) // a canary without a document is never "fresh"
            }
            checkCanary(d, false)
            val key = d.active ?: return DiscoverResult.Absent
            val s = d.scopes.first { it.key == key }
            if (!s.ready) return DiscoverResult.Unavailable(AdmissionError.NOT_ADMITTED) // bootstrap never confirmed: no cache can be trusted, retry needs an authenticated admit
            if (install() != s.install) fail(AdmissionError.INSTALL_CHANGED)
            custodyOk(s.owner, s.epoch)
            DiscoverResult.Ready(scope(s))
        } catch (e: AdmissionFailure) { DiscoverResult.Unavailable(e.error) }
    }

    /** Explicit admission after Dart authenticated the owner. createAllowed is true in exactly one reply per scope (the call that durably arms it); every later admit of that scope is open-existing-and-confirm only. Native re-checks custody (enabled, same epoch) and the install id. Returns the scope and whether this call may create. */
    fun admit(owner: String, epoch: Long): Admitted = synchronized(lock) {
        checkInput(owner, epoch)
        custodyOk(owner, epoch)
        val inst = install()
        val key = workspaceScopeKey(owner, inst)
        val existing = loadDoc()
        if (existing == null) {
            if (readCanary() != null) fail(AdmissionError.AMBIGUOUS) // canary without a document: never infer a fresh install
            val s = LedgerScope(key, owner, inst, epoch, false)
            val d = AdmissionDoc(randomCanaryId().also { if (!validInstallId(it)) fail(AdmissionError.UNAVAILABLE) }, mutableListOf(s), key)
            saveDoc(d)                      // 1: durable pending scope, active
            checkCanary(d, true)            // 2: create-only canary with the document's id
            s.armed = true; saveDoc(d)      // 2b: durable mark that the canary existed; from here a missing canary is ambiguous, never completed
            prepare()
            return Admitted(scope(s), true)
        }
        checkCanary(existing, true)
        val wasUnarmed = existing.scopes.firstOrNull { it.key == key }?.let { !it.armed } ?: false // no reply was ever issued for it: crash between document write and canary
        if (existing.scopes.any { !it.armed }) { existing.scopes.forEach { it.armed = true }; saveDoc(existing) } // canary verified present with the document id
        if (existing.scopes.any { it.install != inst }) fail(AdmissionError.INSTALL_CHANGED)
        val inUse = existing.active?.let { a -> existing.scopes.first { it.key == a } }
        if (inUse != null && inUse.key != key) fail(AdmissionError.OWNER_CONFLICT) // another owner is active; it must be invalidated (logout/opt-out) first
        val known = existing.scopes.firstOrNull { it.key == key }
        if (known != null) {
            if (known.epoch != epoch) fail(AdmissionError.EPOCH_MISMATCH) // an epoch rise needs a policy decision (new scope or purge) that is not invented here
            if (existing.active != key) { existing.active = key; saveDoc(existing) }
            prepare()
            return Admitted(scope(known), wasUnarmed) // create permission is issued exactly once per scope (the arming call); an armed pending scope is open-existing-and-confirm only
        }
        if (existing.scopes.size >= MAX_SCOPES) fail(AdmissionError.LEDGER_FULL)
        val s = LedgerScope(key, owner, inst, epoch, false, true)
        existing.scopes.add(s); existing.active = key
        saveDoc(existing)
        prepare()
        return Admitted(scope(s), true)
    }

    /** After Dart's SQLCipher bootstrap succeeded for the admitted scope: pending -> ready. Idempotent. Re-checks custody and install. */
    fun confirm(owner: String, epoch: Long): WorkspaceScope = synchronized(lock) {
        checkInput(owner, epoch)
        val d = loadDoc() ?: fail(AdmissionError.NOT_ADMITTED)
        checkCanary(d, false)
        custodyOk(owner, epoch)
        val key = workspaceScopeKey(owner, install())
        val s = d.scopes.firstOrNull { it.key == key && it.epoch == epoch } ?: fail(AdmissionError.NOT_ADMITTED)
        if (d.active != key) fail(AdmissionError.NOT_ADMITTED)
        if (!s.ready) { s.ready = true; saveDoc(d) }
        scope(s)
    }

    /** Logout, opt-out or owner switch: durably removes ONLY the cold selection when [owner] is the active one. Never touches the scope, canary, key or database. True when it changed. */
    fun invalidate(owner: String): Boolean = synchronized(lock) {
        if (!validCustodyId(owner)) fail(AdmissionError.INVALID_INPUT)
        val d = loadDoc() ?: return false
        val a = d.active?.let { k -> d.scopes.first { it.key == k } } ?: return false
        if (a.owner != owner) return false
        d.active = null
        saveDoc(d)
        true
    }
}

/** Definite presence of the admission document, by file-system facts only. A FileNotFoundException from opening a file also means "exists but unreadable" (permission, directory), so it is never used as absence.
 * ABSENT only when the directory itself is definitely not there, or the directory is a real directory and neither the base file nor AtomicFile's leftovers (.bak, .new) exist. A non-directory parent, a
 * base that is not a regular file, and any check that cannot decide (unknown) are UNKNOWN or PRESENT, so the caller must read (and fail closed on any error) or fail. */
enum class DocPresence { ABSENT, PRESENT, UNKNOWN }
fun admissionDocPresence(dir: java.io.File, name: String = "admission"): DocPresence {
    val nf = arrayOf(java.nio.file.LinkOption.NOFOLLOW_LINKS)
    val d = dir.toPath()
    try {
        if (java.nio.file.Files.notExists(d, *nf)) return DocPresence.ABSENT
        if (!java.nio.file.Files.isDirectory(d, *nf)) return DocPresence.UNKNOWN
        val base = d.resolve(name)
        val others = listOf(base, d.resolve("$name.bak"), d.resolve("$name.new"))
        if (others.all { java.nio.file.Files.notExists(it, *nf) }) return DocPresence.ABSENT
        return if (java.nio.file.Files.isRegularFile(base, *nf) || others.drop(1).any { java.nio.file.Files.exists(it, *nf) }) DocPresence.PRESENT else DocPresence.UNKNOWN
    } catch (_: Exception) { return DocPresence.UNKNOWN }
}
