package org.otpanda.totp

// MethodChannel-facing adapter for WorkspaceAdmissionCore, free of Flutter types (the host forwards (method, arguments) and maps ChannelReply as for NativeCustodyChannelHandler).
// Channel name (host): app.otpanda/workspace-admission. Arguments are exact-key maps; Long or Int for numbers; anything else is INVALID_INPUT. Nothing is logged.
//
// discover  {}                      -> {status: "ready"|"absent"|"unavailable", reason: String?, scope: Scope?, createAllowed: false}
//                                      reason (unavailable only): an AdmissionError name, scope (ready only). Never an Err for an ordinary unavailable state.
// admit     {owner, epoch}          -> {scope: Scope, createAllowed: Boolean}   | Err(AdmissionError name)
// confirm   {owner, epoch}          -> {scope: Scope}                           | Err(AdmissionError name)
// invalidate{owner}                 -> {invalidated: Boolean}                   | Err(AdmissionError name)
// Scope = {owner, install, epoch (Long), namespace (<= 64 chars, [A-Za-z0-9_-]), path (absolute, private noBackup)}
// Unknown methods are notImplemented. A thrown non-admission error is reported by the host as UNAVAILABLE.

class WorkspaceAdmissionChannelHandler(private val core: WorkspaceAdmissionCore) {
    private class Bad : Exception()
    private fun Map<*, *>.str(k: String) = (this[k] as? String) ?: throw Bad()
    private fun Map<*, *>.long(k: String): Long = when (val v = this[k]) { is Long -> v; is Int -> v.toLong(); else -> throw Bad() }
    private fun Map<*, *>.exact(vararg keys: String) { if (this.keys != keys.toSet()) throw Bad() }
    private fun scopeMap(s: WorkspaceScope) = mapOf("owner" to s.owner, "install" to s.install, "epoch" to s.epoch, "namespace" to s.namespace, "path" to s.path)
    private val known = setOf("discover", "admit", "confirm", "invalidate")

    fun handle(method: String, arguments: Any?): ChannelReply {
        if (method !in known) return ChannelReply.NotImplemented
        return try {
            val a = (arguments as? Map<*, *>) ?: if (method == "discover" && arguments == null) emptyMap<Any, Any>() else throw Bad()
            when (method) {
                "discover" -> { a.exact(); when (val r = core.discover()) {
                    is DiscoverResult.Ready -> ChannelReply.Ok(mapOf("status" to "ready", "reason" to null, "scope" to scopeMap(r.scope), "createAllowed" to false))
                    DiscoverResult.Absent -> ChannelReply.Ok(mapOf("status" to "absent", "reason" to null, "scope" to null, "createAllowed" to false))
                    is DiscoverResult.Unavailable -> ChannelReply.Ok(mapOf("status" to "unavailable", "reason" to r.reason.name, "scope" to null, "createAllowed" to false))
                } }
                "admit" -> { a.exact("owner", "epoch"); core.admit(a.str("owner"), a.long("epoch")).let { ChannelReply.Ok(mapOf("scope" to scopeMap(it.scope), "createAllowed" to it.createAllowed)) } }
                "confirm" -> { a.exact("owner", "epoch"); ChannelReply.Ok(mapOf("scope" to scopeMap(core.confirm(a.str("owner"), a.long("epoch"))))) }
                "invalidate" -> { a.exact("owner"); ChannelReply.Ok(mapOf("invalidated" to core.invalidate(a.str("owner")))) }
                else -> ChannelReply.NotImplemented
            }
        } catch (e: AdmissionFailure) { ChannelReply.Err(e.error.name) }
        catch (_: Bad) { ChannelReply.Err(AdmissionError.INVALID_INPUT.name) }
    }
}
