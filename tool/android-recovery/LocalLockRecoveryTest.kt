package org.otpanda.recovery

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executor

// JVM logic tests with fakes. Not OS credential UI, real network, lifecycle, or device evidence.
private class Manual : Executor { val q = ArrayDeque<Runnable>(); override fun execute(r: Runnable) { q.addLast(r) } }
private const val NOW = 1_800_000_000_000L
private val TOKEN = "otpda_" + "a".repeat(55)
private val CHALLENGE = "c".repeat(43)

private class Env : LockEnv {
    var now = NOW; var device: String? = "dev1"
    override fun nowMs() = now
    override fun random32() = ByteArray(32) { (n++).toByte() }.also { n += 7 }
    override fun deviceId() = device
    var n = 1
}
private class Effects : LockEffects { var enabled = true; var disableOk = true; var disables = 0
    override fun lockEnabled() = enabled
    override fun disable(): Boolean { disables++; if (disableOk) enabled = false; return disableOk } }
private class Api : LockApi {
    val calls = ArrayList<Triple<String, String, String>>()
    val script = ArrayDeque<() -> ApiResult>()
    var onCall: ((String) -> Unit)? = null
    override fun post(path: String, bearer: String, body: ByteArray): ApiResult {
        calls.add(Triple(path, bearer, String(body))); onCall?.invoke(path); return script.removeFirst()()
    }
}
private class Pk : PasskeyAssertion {
    var requests = ArrayList<String>(); var done: ((AssertionResult) -> Unit)? = null; var cancelled = 0
    var onGet: (() -> Unit)? = null
    override fun get(requestJson: String, done: (AssertionResult) -> Unit): Cancellable { requests.add(requestJson); this.done = done; onGet?.invoke(); return Cancellable { cancelled++ } }
}
private fun beginJson(rp: String = "otpanda.github.io", uv: String = "required", ch: String = CHALLENGE, exp: Long = NOW + 60_000, token: String = TOKEN, allow: String = """[{"id":"abc_-1"}]""") =
    """{"token":"$token","options":{"rpId":"$rp","userVerification":"$uv","challenge":"$ch","allowCredentials":$allow},"expiresAt":$exp}"""
private const val ASSERT = """{"type":"public-key","id":"i","rawId":"r","response":{"clientDataJSON":"a","authenticatorData":"b","signature":"c","userHandle":"u"}}"""
private fun ok(s: String) = { ApiResult(200, s.toByteArray()) }
private fun status(c: Int) = { ApiResult(c, "{}".toByteArray()) }
private fun lg(api: Api) = Regex("\"lockGeneration\":\"([A-Za-z0-9_-]+)\"").find(api.calls.first().third)!!.groupValues[1]
private fun finishJson(intent: String, g: String, dev: String = "dev1", gen: String = "3", extra: String = "") =
    """{"intent":"$intent","lockGeneration":"$g","deviceId":"$dev","generation":$gen$extra}"""

private class T(val intent: LockIntent = LockIntent.DISABLE) {
    val env = Env(); val fx = Effects(); val api = Api(); val pk = Pk(); val io = Manual(); val main = Manual()
    val rec = LocalLockRecovery(api, pk, fx, env, io, main)
    val out = ArrayList<LockOutcome>()
    fun start(i: LockIntent = intent, bearer: String = "bearer-token-0123456789") = rec.start(i, bearer) { out.add(it) }
    fun pump() { while (io.q.isNotEmpty() || main.q.isNotEmpty()) { io.q.removeFirstOrNull()?.run(); main.q.removeFirstOrNull()?.run() } }
    /** Runs a whole attempt to the passkey prompt. */
    fun toPrompt() { api.script.add(ok(beginJson())); start(); pump(); check(pk.requests.size == 1) { "no prompt: $out" } }
    fun answer(r: AssertionResult = AssertionResult.Json(ASSERT)) { pk.done!!(r); pump() }
}
private fun expect(t: T, o: LockOutcome) { check(t.out == listOf(o)) { "expected $o got ${t.out}" } }

private fun connection(url: URL, status: Int, body: ByteArray, failWrite: Boolean = false, failRead: Boolean = false) = object : HttpURLConnection(url) {
    val sent = ByteArrayOutputStream(); val props = HashMap<String, String>(); var disconnected = false
    override fun setRequestProperty(k: String, v: String) { props[k] = v }
    override fun getOutputStream() = if (failWrite) throw java.io.IOException("w") else sent
    override fun getResponseCode() = if (failRead) throw java.io.IOException("r") else status
    override fun getInputStream() = ByteArrayInputStream(body)
    override fun getErrorStream() = ByteArrayInputStream(body)
    override fun disconnect() { disconnected = true }
    override fun usingProxy() = false
    override fun connect() {}
}

fun main() {
    // Happy disable: exact bodies, bearer, effect once, after the validated finish only.
    run {
        val t = T(); t.toPrompt()
        val (p, bearer, body) = t.api.calls[0]
        check(p == "/v1/manage/local-lock/begin" && bearer == "bearer-token-0123456789")
        val g = lg(t.api); check(g.length == 43 && body == """{"intent":"local-lock-disable","lockGeneration":"$g"}""") { body }
        val req = Json.parseObject(t.pk.requests[0].toByteArray())!!
        check(req["rpId"] == "otpanda.github.io" && req["userVerification"] == "required" && req["challenge"] == CHALLENGE && req["timeout"] == 60000L && req["allowCredentials"] == listOf(mapOf("type" to "public-key", "id" to "abc_-1")))
        check(t.fx.disables == 0)
        t.api.script.add(ok(finishJson("local-lock-disable", g))); t.answer()
        val f = Json.parseObject(t.api.calls[1].third.toByteArray())!!
        check(t.api.calls[1].first.endsWith("/finish") && f.keys == setOf("intent", "lockGeneration", "token", "response") && f["token"] == TOKEN && f["lockGeneration"] == g)
        val resp = f["response"] as Map<*, *>; check(resp["type"] == "public-key" && (resp["response"] as Map<*, *>)["signature"] == "c")
        expect(t, LockOutcome.DISABLED); check(t.fx.disables == 1 && !t.fx.enabled)
    }
    // Happy unlock: one-use grant with TTL; nothing before the finish.
    run {
        val t = T(LockIntent.UNLOCK_ONCE); t.toPrompt(); check(!t.rec.consumeUnlock())
        t.api.script.add(ok(finishJson("local-unlock-once", lg(t.api)))); t.answer()
        expect(t, LockOutcome.UNLOCK_GRANTED); check(t.fx.disables == 0)
        check(t.rec.consumeUnlock()); check(!t.rec.consumeUnlock())
        val u = T(LockIntent.UNLOCK_ONCE); u.toPrompt(); u.api.script.add(ok(finishJson("local-unlock-once", lg(u.api)))); u.answer(); u.env.now += 15_001; check(!u.rec.consumeUnlock())
        val w = T(LockIntent.UNLOCK_ONCE); w.toPrompt(); w.api.script.add(ok(finishJson("local-unlock-once", lg(w.api)))); w.answer(); w.env.now -= 1; check(!w.rec.consumeUnlock()) // clock stepped back
    }
    // Finish response must match this exact operation; otherwise no effect.
    run {
        fun bad(mut: (String) -> String) { val t = T(); t.toPrompt(); t.api.script.add(ok(mut(lg(t.api)))); t.answer(); expect(t, LockOutcome.MISMATCH); check(t.fx.disables == 0 && t.fx.enabled) }
        bad { finishJson("local-unlock-once", it) }
        bad { finishJson("local-lock-disable", "x".repeat(43)) }
        bad { finishJson("local-lock-disable", it, dev = "other") }
        bad { finishJson("local-lock-disable", it, extra = ""","x":1""") }
        bad { finishJson("local-lock-disable", it, gen = "\"3\"") }
        bad { finishJson("local-lock-disable", it, gen = "-1") }
        bad { finishJson("local-lock-disable", it, gen = "3.5") }
        bad { """{"intent":"local-lock-disable","lockGeneration":"$it","deviceId":"dev1"}""" }
        bad { "[]" }; bad { "not json" }; bad { finishJson("local-lock-disable", it) + "x" }
        bad { """{"intent":"local-lock-disable","intent":"local-lock-disable","lockGeneration":"$it","deviceId":"dev1","generation":3}""" }
    }
    // Invalid begin responses never reach the passkey prompt.
    run {
        for (b in listOf(beginJson(rp = "evil.example"), beginJson(uv = "preferred"), beginJson(ch = "short"), beginJson(exp = NOW), beginJson(exp = NOW + 120_001), beginJson(token = "tok"),
            beginJson(allow = "[" + (0..50).joinToString(",") { """{"id":"a$it"}""" } + "]"), beginJson(allow = """[{"id":""}]"""), beginJson(allow = """[{"id":"a b"}]"""), "{}", "x")) {
            val t = T(); t.api.script.add(ok(b)); t.start(); t.pump(); expect(t, LockOutcome.MISMATCH); check(t.pk.requests.isEmpty() && t.api.calls.size == 1)
        }
    }
    // Honest failures: nothing changed unless the outcome is unknown, and never a local effect.
    run {
        fun begin(f: () -> ApiResult, o: LockOutcome) { val t = T(); t.api.script.add(f); t.start(); t.pump(); expect(t, o); check(t.pk.requests.isEmpty()) }
        begin({ throw ApiUnreachable() }, LockOutcome.NETWORK_UNAVAILABLE); begin({ throw ApiUnknown() }, LockOutcome.NETWORK_UNAVAILABLE)
        begin(status(401), LockOutcome.UNAUTHORIZED); begin(status(403), LockOutcome.RESTART); begin(status(429), LockOutcome.SERVER_BUSY); begin(status(400), LockOutcome.INVALID); begin(status(503), LockOutcome.UNAVAILABLE)
        fun fin(f: () -> ApiResult, o: LockOutcome) { val t = T(); t.toPrompt(); t.api.script.add(f); t.answer(); expect(t, o); check(t.fx.disables == 0 && t.fx.enabled && !t.rec.consumeUnlock()) }
        fin({ throw ApiUnreachable() }, LockOutcome.NETWORK_UNAVAILABLE); fin({ throw ApiUnknown() }, LockOutcome.OUTCOME_UNKNOWN); fin(status(503), LockOutcome.OUTCOME_UNKNOWN)
        fin(status(401), LockOutcome.UNAUTHORIZED); fin(status(403), LockOutcome.RESTART); fin(status(429), LockOutcome.SERVER_BUSY); fin(status(302), LockOutcome.UNAVAILABLE)
        fin({ throw IllegalStateException("x") }, LockOutcome.OUTCOME_UNKNOWN)
        val s = T(); s.toPrompt(); s.api.script.add(ok(finishJson("local-lock-disable", lg(s.api)))); s.fx.disableOk = false; s.answer(); expect(s, LockOutcome.STORAGE)
    }
    // Passkey outcomes.
    run {
        val t = T(); t.toPrompt(); t.answer(AssertionResult.UserCancelled); expect(t, LockOutcome.USER_CANCELLED); check(t.api.calls.size == 1)
        val u = T(); u.toPrompt(); u.answer(AssertionResult.Unavailable); expect(u, LockOutcome.PASSKEY_UNAVAILABLE)
        val v = T(); v.toPrompt(); v.answer(AssertionResult.Json("""{"type":"public-key","id":"i"}""")); expect(v, LockOutcome.MISMATCH); check(v.api.calls.size == 1)
        val w = T(); w.api.script.add(ok(beginJson())); w.start(); w.pk.onGet = null
        val x = object : PasskeyAssertion { override fun get(requestJson: String, done: (AssertionResult) -> Unit): Cancellable = throw IllegalStateException() }
        val y = T(); val rec = LocalLockRecovery(y.api, x, y.fx, y.env, y.io, y.main); y.api.script.add(ok(beginJson())); rec.start(LockIntent.DISABLE, "bearer-token-0123456789") { y.out.add(it) }; y.pump(); expect(y, LockOutcome.PASSKEY_UNAVAILABLE)
    }
    // Lifecycle: reset ends the attempt once at every stage and late results change nothing.
    run {
        val a = T(); a.api.script.add(ok(beginJson())); a.start(); a.rec.reset(); a.pump(); expect(a, LockOutcome.ABORTED); check(a.pk.requests.isEmpty())
        val b = T(); b.toPrompt(); b.rec.reset(); check(b.pk.cancelled == 1); b.answer(); expect(b, LockOutcome.ABORTED); check(b.api.calls.size == 1)
        val c = T(); c.toPrompt(); c.api.script.add(ok(finishJson("local-lock-disable", lg(c.api)))); c.pk.done!!(AssertionResult.Json(ASSERT)); c.main.q.removeFirst().run(); c.io.q.removeFirst().run(); c.rec.reset(); c.pump()
        expect(c, LockOutcome.ABORTED); check(c.fx.disables == 0 && c.fx.enabled)
        val d = T(); d.api.script.add(ok(beginJson())); d.start(); d.rec.reset(); d.rec.start(LockIntent.DISABLE, "bearer-token-0123456789") { d.out.add(it) }; // new attempt while the old begin is in flight
        check(d.out == listOf(LockOutcome.ABORTED)); d.api.script.add(ok(beginJson())); d.pump()
        check(d.pk.requests.size == 1) { "only the new attempt prompts: ${d.pk.requests.size}" }
        // reset after completion is harmless and a new attempt after reset gets a fresh lock generation
        val e = T(); e.toPrompt(); val g1 = lg(e.api); e.rec.reset(); e.api.calls.clear(); e.api.script.add(ok(beginJson())); e.out.clear(); e.start(); e.pump(); check(lg(e.api) != g1)
        val f = T(); f.rec.reset(); check(f.out.isEmpty())
    }
    // Context binding: device change or lock turned off aborts before the prompt, before finish and before the effect.
    run {
        val a = T(); a.api.script.add(ok(beginJson())); a.start(); a.env.device = "dev2"; a.pump(); expect(a, LockOutcome.ABORTED); check(a.pk.requests.isEmpty())
        val b = T(); b.toPrompt(); b.env.device = null; b.answer(); expect(b, LockOutcome.ABORTED); check(b.api.calls.size == 1)
        val c = T(); c.toPrompt(); c.api.script.add(ok(finishJson("local-lock-disable", lg(c.api)))); c.api.onCall = { if (it.endsWith("finish")) c.env.device = "dev2" }; c.answer(); expect(c, LockOutcome.ABORTED); check(c.fx.disables == 0)
        val d = T(); d.toPrompt(); d.fx.enabled = false; d.answer(); expect(d, LockOutcome.ABORTED)
        val e = T(); e.fx.enabled = false; e.start(); expect(e, LockOutcome.NOT_ENABLED)
        val f = T(); f.env.device = null; f.start(); expect(f, LockOutcome.NO_DEVICE)
        val g = T(); g.api.script.add(ok(beginJson())); g.start(); g.start(); check(g.out == listOf(LockOutcome.BUSY))
        val h = T(); h.start(bearer = "has space bearer-token"); expect(h, LockOutcome.INVALID); check(h.api.calls.isEmpty())
        val i = T(); i.start(bearer = "short"); expect(i, LockOutcome.INVALID)
    }
    // Strict JSON.
    run {
        check(Json.parseObject("""{"a":1,"a":2}""".toByteArray()) == null); check(Json.parseObject("""{"a":1} x""".toByteArray()) == null)
        check(Json.parseObject("[1]".toByteArray()) == null); check(Json.parseObject("""{"a":"\u0041\n"}""".toByteArray())!!["a"] == "A\n")
        check(Json.parseObject("""{"a":[[[[[[[[[[1]]]]]]]]]]}""".toByteArray()) == null); check(Json.parseObject(ByteArray(24577) { ' '.code.toByte() }) == null)
        check(Json.parseObject(byteArrayOf('{'.code.toByte(), 0xC3.toByte(), '}'.code.toByte())) == null); check(Json.parseObject("""{"a":01}""".toByteArray()) == null)
        check(Json.write(mapOf("a" to "x\"\u00e9\n")) == "{\"a\":\"x\\\"\\u00e9\\u000a\"}")
    }
    // HttpsLockApi: fixed origin, paths, no redirects, headers, failure classes.
    run {
        check(runCatching { HttpsLockApi("http://x.example") }.isFailure && runCatching { HttpsLockApi("https://x.example/p") }.isFailure)
        var made: HttpURLConnection? = null
        fun api(status: Int = 200, body: ByteArray = "{}".toByteArray(), w: Boolean = false, r: Boolean = false) = HttpsLockApi("https://api.example") { made = connection(it, status, body, w, r); made!! }
        val res = api().post("/v1/manage/local-lock/begin", "tok-0123456789abcdef", "{}".toByteArray())
        check(res.status == 200 && !made!!.instanceFollowRedirects && !made!!.useCaches && made!!.url.toString() == "https://api.example/v1/manage/local-lock/begin")
        check(made!!.requestMethod == "POST")
        check(runCatching { api().post("/v1/other", "t", "{}".toByteArray()) }.isFailure)
        check(runCatching { api(w = true).post("/v1/manage/local-lock/begin", "t", "{}".toByteArray()) }.exceptionOrNull() is ApiUnreachable)
        check(runCatching { api(r = true).post("/v1/manage/local-lock/finish", "t", "{}".toByteArray()) }.exceptionOrNull() is ApiUnknown)
        check(runCatching { api(body = ByteArray(24577)).post("/v1/manage/local-lock/finish", "t", "{}".toByteArray()) }.exceptionOrNull() is ApiUnknown)
        check(api(status = 503).post("/v1/manage/local-lock/finish", "t", "{}".toByteArray()).status == 503)
        check(api(status = 302).post("/v1/manage/local-lock/finish", "t", "{}".toByteArray()).status == 302)
    }
    println("PASS LocalLockRecovery JVM logic and transport tests (fakes only; no OS UI, network, lifecycle or device evidence)")
}
