package app.otpanda

import android.content.Context
import android.util.AtomicFile
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import org.json.JSONObject

/** Recovery metadata only. Atomic CAS, app-private/no-backup. No seed payload.
 * Session changes never clear it. The Dart owner/session/lock fence decides
 * when it can be read for reconciliation. An unreadable file blocks claims. */
class ImportJournalStore(context: Context) {
    companion object { private val lock = Any(); private const val MAX = 1024 }
    private val file = AtomicFile(File(context.noBackupFilesDir, "otpanda-import-attempt-v2"))
    private fun checked(raw: String): String {
        require(raw.toByteArray(Charsets.UTF_8).size <= MAX)
        val o = JSONObject(raw)
        require(o.keys().asSequence().toSet() == setOf("v","ownerId","deviceId","nonce","admissionId","count","outcome"))
        require(o.get("v") is Int && o.getInt("v") == 2)
        require(o.getString("outcome") in setOf("pending","saved","fenced"))
        for (k in listOf("ownerId","deviceId")) require(o.get(k) is String && Regex("^[A-Za-z0-9_-]{1,128}$").matches(o.getString(k)))
        require(o.get("nonce") is String && Regex("^v2:[A-Za-z0-9_-]{22,61}$").matches(o.getString("nonce")))
        require(o.get("admissionId") is String && Regex("^[A-Za-z0-9_-]{22,64}$").matches(o.getString("admissionId")))
        require(o.get("count") is Int && o.getInt("count") in 1..50)
        return raw
    }
    fun read(): String? = synchronized(lock) {
        try { file.openRead().use { s ->
            val b = java.io.ByteArrayOutputStream().also { out ->
                var n = 0
                while(n <= MAX) { val v=s.read(); if(v<0)break; out.write(v); n++ }
            }.toByteArray()
            require(b.size <= MAX)
            checked(b.toString(Charsets.UTF_8))
        } } catch (e: java.io.FileNotFoundException) {
            if (file.baseFile.exists() || File(file.baseFile.path + ".bak").exists()) throw e
            null
        }
    }
    fun claim(raw: String): Boolean = synchronized(lock) {
        require(JSONObject(checked(raw)).getString("outcome") == "pending")
        if (read() != null) return@synchronized false
        val stream = file.startWrite()
        try { stream.write(raw.toByteArray(Charsets.UTF_8)); file.finishWrite(stream) }
        catch(e: Exception) { file.failWrite(stream); throw e }
        true
    }
    fun replace(expected: String, raw: String): Boolean = synchronized(lock) {
        val old = JSONObject(checked(expected)); val next = JSONObject(checked(raw))
        require(old.getString("outcome") == "pending" && next.getString("outcome") in setOf("saved","fenced"))
        for(k in listOf("v","ownerId","deviceId","nonce","admissionId","count")) require(old.get(k) == next.get(k))
        if(read() != expected) return@synchronized false
        val stream = file.startWrite()
        try { stream.write(raw.toByteArray(Charsets.UTF_8)); file.finishWrite(stream) }
        catch(e: Exception) { file.failWrite(stream); throw e }
        true
    }
    fun clear(expected: String): Boolean = synchronized(lock) {
        require(JSONObject(checked(expected)).getString("outcome") in setOf("saved","fenced"))
        if (read() != expected) return@synchronized false
        file.delete()
        require(read() == null)
        true
    }
}

object ImportJournalHost {
    fun register(context: Context, messenger: BinaryMessenger) {
        val store = ImportJournalStore(context.applicationContext)
        MethodChannel(messenger,"app.otpanda/import-journal").setMethodCallHandler { call,result ->
            try {
                when(call.method) {
                    "read" -> result.success(store.read())
                    "claim" -> result.success(store.claim(call.argument<String>("record") ?: throw IllegalArgumentException()))
                    "replace" -> result.success(store.replace(call.argument<String>("expected") ?: throw IllegalArgumentException(),call.argument<String>("record") ?: throw IllegalArgumentException()))
                    "clear" -> result.success(store.clear(call.argument<String>("record") ?: throw IllegalArgumentException()))
                    else -> result.notImplemented()
                }
            } catch (_: Exception) { result.error("storage_unavailable",null,null) }
        }
    }
}
