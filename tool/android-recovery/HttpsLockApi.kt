package org.otpanda.recovery

import java.net.HttpURLConnection
import java.net.URL

/** Fixed-origin HTTPS transport for LocalLockRecovery. Only the two local-lock paths, POST only, no redirects, no cookies, no Origin header, bounded request and response,
 * system TLS trust only (no custom TrustManager). [open] exists so tests can substitute a connection. */
class HttpsLockApi(
    private val origin: String = "https://otpanda-api.abrahammurciano.workers.dev",
    private val open: (URL) -> HttpURLConnection = { it.openConnection() as HttpURLConnection },
) : LockApi {
    init { require(origin.startsWith("https://") && !origin.removePrefix("https://").contains('/')) }
    override fun post(path: String, bearer: String, body: ByteArray): ApiResult {
        require(path == "/v1/manage/local-lock/begin" || path == "/v1/manage/local-lock/finish")
        require(body.size <= 24576)
        val url = URL(origin + path)
        require(url.protocol == "https")
        var sent = false
        try {
            val c = open(url)
            try {
                c.requestMethod = "POST"; c.instanceFollowRedirects = false; c.useCaches = false; c.connectTimeout = 10_000; c.readTimeout = 20_000
                c.setRequestProperty("Content-Type", "application/json"); c.setRequestProperty("Accept", "application/json"); c.setRequestProperty("Authorization", "Bearer $bearer")
                c.doOutput = true; c.setFixedLengthStreamingMode(body.size)
                c.outputStream.use { it.write(body) }
                sent = true
                val status = c.responseCode
                val stream = if (status in 200..299) c.inputStream else c.errorStream
                val bytes = stream?.use { readBounded(it, 24577) } ?: ByteArray(0)
                if (bytes.size > 24576) throw ApiUnknown()
                return ApiResult(status, bytes)
            } finally { c.disconnect() }
        } catch (e: ApiUnknown) { throw e }
        catch (e: java.io.IOException) { throw if (sent) ApiUnknown() else ApiUnreachable() }
    }
    private fun readBounded(s: java.io.InputStream, limit: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream(); val buf = ByteArray(1024)
        while (out.size() < limit) { val n = s.read(buf, 0, minOf(buf.size, limit - out.size())); if (n < 0) break; out.write(buf, 0, n) }
        return out.toByteArray()
    }
}
