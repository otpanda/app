package org.otpanda.recovery

import java.util.concurrent.Executor

// TEST ONLY. Cross-language contract runner: drives the real LocalLockRecovery core with a transport and a "passkey" that talk over stdin/stdout lines to a parent
// process (the API test in test/local-lock-kotlin-contract.test.js), which answers with the REAL server handlers and a real WebAuthn authenticator fixture.
// Usage: LocalLockContractRunnerKt <intent> <bearer> <deviceId>. Not part of the app.
// Lines out: {"t":"http","path":..,"bearer":..,"body":..} | {"t":"passkey","request":..} | {"t":"outcome","outcome":..,"disables":N,"unlock":bool}
// Lines in:  {"status":N,"body":".."} for http, {"assertion":".."} for passkey (null means the user cancelled).
fun main(args: Array<String>) {
    val reader = System.`in`.bufferedReader()
    fun send(m: Map<String, Any?>) { println(Json.write(m)); System.out.flush() }
    fun recv(): Map<String, Any?> = Json.parseObject((reader.readLine() ?: error("parent closed")).toByteArray(Charsets.UTF_8)) ?: error("bad line")
    val direct = Executor { it.run() }
    var disables = 0; var enabled = true
    val fx = object : LockEffects { override fun lockEnabled() = enabled; override fun disable(): Boolean { disables++; enabled = false; return true } }
    val env = object : LockEnv {
        override fun nowMs() = System.currentTimeMillis(); override fun elapsedMs() = System.nanoTime() / 1_000_000
        override fun random32() = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }; override fun deviceId(): String? = args[2]
    }
    val api = object : LockApi {
        override fun post(path: String, bearer: String, body: ByteArray): ApiResult {
            send(mapOf("t" to "http", "path" to path, "bearer" to bearer, "body" to String(body, Charsets.UTF_8)))
            val r = recv(); return ApiResult((r["status"] as Long).toInt(), (r["body"] as String).toByteArray(Charsets.UTF_8))
        }
    }
    val pk = object : PasskeyAssertion {
        override fun get(requestJson: String, done: (AssertionResult) -> Unit): Cancellable {
            send(mapOf("t" to "passkey", "request" to requestJson))
            val a = recv()["assertion"] as? String; done(if (a == null) AssertionResult.UserCancelled else AssertionResult.Json(a)); return Cancellable { }
        }
    }
    val rec = LocalLockRecovery(api, pk, fx, env, direct, direct)
    val intent = LockIntent.entries.first { it.wire == args[0] }
    var outcome: LockOutcome? = null
    rec.start(intent, args[1]) { outcome = it }
    send(mapOf("t" to "outcome", "outcome" to outcome?.name, "disables" to disables.toLong(), "unlock" to rec.consumeUnlock()))
}
