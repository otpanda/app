package org.otpanda.recovery

import java.util.concurrent.Executor

// Native-owned finish for the local app-lock recovery ceremonies (intents local-unlock-once and local-lock-disable). PROPOSAL, inactive: not registered
// with any Activity or channel. Pure JVM logic over small interfaces. It owns the whole ceremony: it picks the lockGeneration, runs begin and finish over
// a fixed HTTPS origin, validates the finish response against the exact pending operation (intent, lockGeneration, device, shape) and only then performs
// the local effect itself. Dart only starts an attempt and receives a coarse outcome. There is no channel method that disables or unlocks by itself.
//
// The server contract (otpanda-api src/local-lock-recovery-http.js): POST /v1/manage/local-lock/{begin,finish}, bearer device session, no Origin header,
// application/json. begin body {intent, lockGeneration}; finish body {intent, lockGeneration, response, token}; 200 finish body
// {intent, lockGeneration, deviceId, generation}. Server binds ["local-lock-v1", owner, device, security generation, lockGeneration] to a one-use passkey ceremony.
//
// Not claimed: OS credential UI behavior, real network, process death, multi-window, clock behavior. The server does not echo the owner, so the native side
// binds the device and the lock generation, not the owner: the owner is bound only through the bearer the host passes in.

enum class LockIntent(val wire: String) { UNLOCK_ONCE("local-unlock-once"), DISABLE("local-lock-disable") }

enum class LockOutcome {
    DISABLED, UNLOCK_GRANTED,
    /** The user dismissed the passkey prompt. Nothing changed. */
    USER_CANCELLED,
    /** Lifecycle or session reset (activity stop/destroy, sign-out, session change) ended the attempt. Nothing changed. */
    ABORTED,
    /** Nothing was sent or the server was never reached. Nothing changed. */
    NETWORK_UNAVAILABLE,
    /** The finish request may have been applied (the one-use ceremony may be consumed) but its answer was not usable. No local effect was made. Retry from the start. */
    OUTCOME_UNKNOWN,
    UNAUTHORIZED, RESTART, SERVER_BUSY, INVALID, UNAVAILABLE, NOT_ENABLED, NO_DEVICE, PASSKEY_UNAVAILABLE,
    /** The server answered 200 but the answer did not match this exact operation. No local effect was made. */
    MISMATCH, STORAGE, BUSY,
}

class ApiUnreachable : Exception()
/** The request may have been delivered but no usable response arrived. */
class ApiUnknown : Exception()
class ApiResult(val status: Int, val body: ByteArray)

interface LockApi { /** Blocking. Never follows redirects. */ fun post(path: String, bearer: String, body: ByteArray): ApiResult }

sealed class AssertionResult {
    class Json(val value: String) : AssertionResult()
    object UserCancelled : AssertionResult()
    object Unavailable : AssertionResult()
}
interface PasskeyAssertion {
    /** Starts the system prompt. [done] is invoked at most once. [cancel] must be honored: after it, results are ignored by the caller anyway. */
    fun get(requestJson: String, done: (AssertionResult) -> Unit): Cancellable
}
fun interface Cancellable { fun cancel() }

interface LockEffects {
    fun lockEnabled(): Boolean
    /** Removes the enabled flag and the secure-window flag. True only when the lock is verifiably off afterwards. */
    fun disable(): Boolean
}

interface LockEnv {
    /** Wall clock. Used only to judge the server's begin expiry. */
    fun nowMs(): Long
    /** Monotonic milliseconds (SystemClock.elapsedRealtime on Android). Used for the one-use unlock TTL so a wall-clock change cannot extend or break it. */
    fun elapsedMs(): Long
    fun random32(): ByteArray
    /** The native-stored enrolled device id, or null. Read again before the effect. */
    fun deviceId(): String?
}

private const val BEGIN = "/v1/manage/local-lock/begin"
private const val FINISH = "/v1/manage/local-lock/finish"
private val tokenRe = Regex("^otpda_[A-Za-z0-9_-]{55}$")
private val b64u43 = Regex("^[A-Za-z0-9_-]{43}$")
private val b64u = Regex("^[A-Za-z0-9_-]+$")
private const val RP_ID = "otpanda.github.io"
private const val MAX_SAFE = 9007199254740991L
/** Server ceremony TTL is 120 s. A device clock behind the server sees up to TTL + lag remaining; one ahead sees less and fails closed once expired.
 * Accept remaining time in (0, TTL + BEHIND_TOLERANCE]. The prompt timeout is clamped to the TTL. */
const val CEREMONY_TTL_MS = 120_000L
const val CLOCK_BEHIND_TOLERANCE_MS = 300_000L

class LocalLockRecovery(
    private val api: LockApi, private val passkeys: PasskeyAssertion, private val effects: LockEffects, private val env: LockEnv,
    private val io: Executor, private val main: Executor, private val unlockTtlMs: Long = 15_000,
) {
    private class Op(val id: Long, val intent: LockIntent, val lockGeneration: String, val device: String, val bearer: String, val done: (LockOutcome) -> Unit) {
        var cancel: Cancellable? = null
    }
    private val lock = Any()
    private var generation = 0L
    private var op: Op? = null
    private var unlockAt = -1L

    /** Call on the main thread. [done] is called exactly once on [main] unless the host is destroyed. */
    fun start(intent: LockIntent, bearer: String, done: (LockOutcome) -> Unit) {
        if (!Regex("^[\\x21-\\x7e]{16,1024}$").matches(bearer)) return done(LockOutcome.INVALID)
        val device = env.deviceId()
        val me: Op
        synchronized(lock) {
            if (op != null) return done(LockOutcome.BUSY)
            if (!effects.lockEnabled()) return done(LockOutcome.NOT_ENABLED)
            if (device == null) return done(LockOutcome.NO_DEVICE)
            val g = env.random32()
            if (g.size != 32) return done(LockOutcome.UNAVAILABLE)
            me = Op(++generation, intent, java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(g), device, bearer, done)
            op = me
        }
        val body = Json.write(linkedMapOf("intent" to intent.wire, "lockGeneration" to me.lockGeneration)).toByteArray(Charsets.UTF_8)
        io.execute {
            val r = try { Result.success(api.post(BEGIN, me.bearer, body)) } catch (e: Exception) { Result.failure(e) }
            main.execute { onBegin(me, r) }
        }
    }

    /** Ends any attempt: activity stop or destroy, sign-out, session or device change. Nothing is applied; late results are dropped. */
    fun reset() {
        val ended: Op?
        synchronized(lock) { generation++; ended = op; op = null; unlockAt = -1 }
        ended?.cancel?.cancel()
        ended?.done?.invoke(LockOutcome.ABORTED)
    }

    /** One-use, short-lived. True only after a validated unlock-once finish, once. */
    fun consumeUnlock(): Boolean = synchronized(lock) {
        val at = unlockAt; unlockAt = -1
        val elapsed = env.elapsedMs() - at
        at >= 0 && elapsed in 0..unlockTtlMs
    }

    private fun live(me: Op) = synchronized(lock) { op === me }
    private fun end(me: Op, outcome: LockOutcome) {
        val ok = synchronized(lock) { if (op === me) { op = null; true } else false }
        if (ok) me.done(outcome)
    }
    private fun statusOutcome(code: Int) = when (code) { 401 -> LockOutcome.UNAUTHORIZED; 403 -> LockOutcome.RESTART; 429 -> LockOutcome.SERVER_BUSY; 400 -> LockOutcome.INVALID; else -> LockOutcome.UNAVAILABLE }

    private fun onBegin(me: Op, r: Result<ApiResult>) {
        if (!live(me)) return
        val res = r.getOrElse { return end(me, if (it is ApiUnknown || it is ApiUnreachable) LockOutcome.NETWORK_UNAVAILABLE else LockOutcome.UNAVAILABLE) }
        if (res.status != 200) return end(me, statusOutcome(res.status))
        val v = Json.parseObject(res.body) ?: return end(me, LockOutcome.MISMATCH)
        val now = env.nowMs()
        val token = v["token"] as? String; val opts = v["options"] as? Map<*, *>; val exp = v["expiresAt"] as? Long
        val allow = opts?.get("allowCredentials") as? List<*>
        if (token == null || !tokenRe.matches(token) || opts == null || opts["rpId"] != RP_ID || opts["userVerification"] != "required" ||
            (opts["challenge"] as? String)?.let { b64u43.matches(it) } != true || allow == null || allow.size > 50 || exp == null || exp <= now || exp > now + CEREMONY_TTL_MS + CLOCK_BEHIND_TOLERANCE_MS)
            return end(me, LockOutcome.MISMATCH)
        val ids = allow.map { ((it as? Map<*, *>)?.get("id") as? String)?.takeIf { s -> s.isNotEmpty() && b64u.matches(s) } ?: return end(me, LockOutcome.MISMATCH) }
        val request = Json.write(linkedMapOf(
            "rpId" to RP_ID, "challenge" to opts["challenge"], "userVerification" to "required", "timeout" to (exp - now).coerceIn(1, CEREMONY_TTL_MS),
            "allowCredentials" to ids.map { linkedMapOf("type" to "public-key", "id" to it) },
        ))
        // Re-check the exact context right before the prompt: device and lock state must not have changed.
        if (env.deviceId() != me.device || !effects.lockEnabled()) return end(me, LockOutcome.ABORTED)
        val cancel = try { passkeys.get(request) { a -> main.execute { onAssertion(me, token, a) } } } catch (_: Exception) { return end(me, LockOutcome.PASSKEY_UNAVAILABLE) }
        synchronized(lock) { if (op === me) me.cancel = cancel else cancel.cancel() }
    }

    private fun onAssertion(me: Op, token: String, a: AssertionResult) {
        if (!live(me)) return
        val json = when (a) {
            AssertionResult.UserCancelled -> return end(me, LockOutcome.USER_CANCELLED)
            AssertionResult.Unavailable -> return end(me, LockOutcome.PASSKEY_UNAVAILABLE)
            is AssertionResult.Json -> a.value
        }
        val j = Json.parseObject(json.toByteArray(Charsets.UTF_8)); val r = j?.get("response") as? Map<*, *>
        if (j == null || r == null || j["type"] != "public-key" || j["id"] !is String || j["rawId"] !is String || r["clientDataJSON"] !is String || r["authenticatorData"] !is String || r["signature"] !is String)
            return end(me, LockOutcome.MISMATCH)
        if (env.deviceId() != me.device || !effects.lockEnabled()) return end(me, LockOutcome.ABORTED)
        val body = Json.write(linkedMapOf(
            "intent" to me.intent.wire, "lockGeneration" to me.lockGeneration, "token" to token,
            "response" to linkedMapOf(
                "id" to j["id"], "rawId" to j["rawId"], "type" to "public-key", "clientExtensionResults" to linkedMapOf<String, Any?>(),
                "response" to linkedMapOf("clientDataJSON" to r["clientDataJSON"], "authenticatorData" to r["authenticatorData"], "signature" to r["signature"],
                    "userHandle" to (r["userHandle"] as? String)),
            ),
        )).toByteArray(Charsets.UTF_8)
        io.execute {
            val res = try { Result.success(api.post(FINISH, me.bearer, body)) } catch (e: Exception) { Result.failure(e) }
            main.execute { onFinish(me, res) }
        }
    }

    private fun onFinish(me: Op, r: Result<ApiResult>) {
        if (!live(me)) return
        val res = r.getOrElse { return end(me, if (it is ApiUnreachable) LockOutcome.NETWORK_UNAVAILABLE else LockOutcome.OUTCOME_UNKNOWN) }
        if (res.status != 200) return end(me, if (res.status in 500..599) LockOutcome.OUTCOME_UNKNOWN else statusOutcome(res.status))
        val v = Json.parseObject(res.body)
        val gen = v?.get("generation")
        if (v == null || v.keys != setOf("intent", "lockGeneration", "deviceId", "generation") || v["intent"] != me.intent.wire || v["lockGeneration"] != me.lockGeneration ||
            v["deviceId"] != me.device || gen !is Long || gen < 0 || gen > MAX_SAFE) return end(me, LockOutcome.MISMATCH)
        // Same device must still be the enrolled one, and this must still be the live operation, at the moment of the effect.
        if (env.deviceId() != me.device) return end(me, LockOutcome.ABORTED)
        when (me.intent) {
            LockIntent.DISABLE -> {
                val ok = synchronized(lock) { if (op !== me) return; effects.disable() }
                end(me, if (ok) LockOutcome.DISABLED else LockOutcome.STORAGE)
            }
            LockIntent.UNLOCK_ONCE -> {
                synchronized(lock) { if (op !== me) return; unlockAt = env.elapsedMs() }
                end(me, LockOutcome.UNLOCK_GRANTED)
            }
        }
    }
}

/** Minimal strict JSON: objects, arrays, strings, integers (Long), other numbers (Double), booleans, null. Rejects duplicate keys, trailing data, depth over 8, size over 24576. */
@Suppress("UNCHECKED_CAST")
object Json {
    fun parseObject(bytes: ByteArray): Map<String, Any?>? {
        if (bytes.size > 24576) return null
        return try {
            val text = Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString()
            val p = P(text); val v = p.value(0); p.ws(); if (p.i != text.length) null else (v as? Map<String, Any?>)
        } catch (_: Exception) { null }
    }
    private class P(val s: String) {
        var i = 0
        fun ws() { while (i < s.length && s[i] in " \t\r\n") i++ }
        fun value(d: Int): Any? {
            require(d <= 8); ws(); require(i < s.length)
            return when (s[i]) {
                '{' -> { i++; val m = LinkedHashMap<String, Any?>(); ws(); if (s[i] == '}') { i++; m } else { while (true) { ws(); val k = str(); ws(); require(s[i++] == ':'); require(!m.containsKey(k)); m[k] = value(d + 1); ws(); if (s[i] == ',') { i++; continue }; require(s[i++] == '}'); break }; m } }
                '[' -> { i++; val l = ArrayList<Any?>(); ws(); if (s[i] == ']') { i++; l } else { while (true) { l.add(value(d + 1)); ws(); if (s[i] == ',') { i++; continue }; require(s[i++] == ']'); break }; l } }
                '"' -> str()
                't' -> lit("true", true); 'f' -> lit("false", false); 'n' -> lit("null", null)
                else -> num()
            }
        }
        fun lit(w: String, v: Any?): Any? { require(s.startsWith(w, i)); i += w.length; return v }
        fun num(): Any {
            val m = Regex("-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?").matchAt(s, i) ?: throw IllegalArgumentException()
            i += m.value.length
            return if (m.groups[2] == null && m.groups[3] == null) m.value.toLong() else m.value.toDouble()
        }
        fun str(): String {
            require(s[i++] == '"'); val b = StringBuilder()
            while (true) {
                val c = s[i++]
                when {
                    c == '"' -> return b.toString()
                    c < ' ' -> throw IllegalArgumentException()
                    c == '\\' -> when (val e = s[i++]) {
                        '"', '\\', '/' -> b.append(e); 'b' -> b.append('\b'); 'f' -> b.append('\u000c'); 'n' -> b.append('\n'); 'r' -> b.append('\r'); 't' -> b.append('\t')
                        'u' -> { b.append(s.substring(i, i + 4).also { require(it.all { h -> h in "0123456789abcdefABCDEF" }) }.toInt(16).toChar()); i += 4 }
                        else -> throw IllegalArgumentException()
                    }
                    else -> b.append(c)
                }
            }
        }
    }
    fun write(v: Any?): String = StringBuilder().also { w(it, v) }.toString()
    private fun w(o: StringBuilder, v: Any?) {
        when (v) {
            null -> o.append("null"); is Boolean, is Int, is Long -> o.append(v.toString())
            is String -> { o.append('"'); for (c in v) when { c == '"' -> o.append("\\\""); c == '\\' -> o.append("\\\\"); c < ' ' || c.code > 0x7e -> o.append("\\u%04x".format(c.code)); else -> o.append(c) }; o.append('"') }
            is Map<*, *> -> { o.append('{'); var f = true; for ((k, x) in v) { if (!f) o.append(','); f = false; w(o, k as String); o.append(':'); w(o, x) }; o.append('}') }
            is List<*> -> { o.append('['); v.forEachIndexed { n, x -> if (n > 0) o.append(','); w(o, x) }; o.append(']') }
            else -> throw IllegalArgumentException()
        }
    }
}
