package org.otpanda.wrappingkey

/**
 * Flutter-free MethodChannel handler. Channel name (host side): "app.otpanda/wrapping-key", the same wire contract as the Windows and macOS adapters:
 * wrappingKeyRead {namespace} -> {key: bytes|null}; wrappingKeyCreate {namespace, key} -> {key, created}; wrappingKeyDelete {namespace} -> {}.
 * Errors: code unavailable | locked | corrupt | missingAlias, details {outcomeUnknown: bool}. Arguments are exact; extra, missing or mistyped ones are
 * unavailable (known not applied). The candidate key array is zeroed on every path. Nothing is logged and no message ever carries a key, namespace or path.
 * The host must serialize calls on one worker (the core also serializes itself).
 */
sealed class WkReply {
    data class Ok(val value: Any?) : WkReply()
    data class Err(val code: String, val outcomeUnknown: Boolean) : WkReply()
    object NotImplemented : WkReply()
}

class WrappingKeyChannelHandler(private val core: WrappingKeyCore) {
    private val known = setOf("wrappingKeyRead", "wrappingKeyCreate", "wrappingKeyDelete")
    private fun bad() = WkReply.Err("unavailable", false)

    fun handle(method: String, arguments: Any?): WkReply {
        val a = arguments as? Map<*, *>
        val key = a?.get("key") as? ByteArray
        try {
            if (method !in known) return WkReply.NotImplemented
            val ns = a?.get("namespace") as? String ?: return bad()
            return when (method) {
                "wrappingKeyRead" -> {
                    if (a.keys != setOf("namespace")) return bad()
                    WkReply.Ok(mapOf("key" to core.read(ns)))
                }
                "wrappingKeyCreate" -> {
                    if (a.keys != setOf("namespace", "key") || key == null) return bad()
                    val r = core.createIfAbsent(ns, key)
                    WkReply.Ok(mapOf("key" to r.first, "created" to r.second))
                }
                else -> {
                    if (a.keys != setOf("namespace")) return bad()
                    core.delete(ns)
                    WkReply.Ok(emptyMap<String, Any?>())
                }
            }
        } catch (e: WrappingKeyFailure) {
            val code = when (e.kind) {
                WrappingKeyFailure.Kind.LOCKED -> "locked"
                WrappingKeyFailure.Kind.CORRUPT -> "corrupt"
                WrappingKeyFailure.Kind.MISSING_ALIAS -> "missingAlias"
                WrappingKeyFailure.Kind.UNAVAILABLE -> "unavailable"
            }
            return WkReply.Err(code, e.outcomeUnknown)
        } catch (_: Exception) {
            // An unexpected failure in a mutation may have applied; a read cannot have.
            return WkReply.Err("unavailable", method != "wrappingKeyRead")
        } finally { key?.fill(0) }
    }
}
