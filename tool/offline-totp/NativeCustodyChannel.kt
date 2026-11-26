package org.otpanda.totp

// Proposal: the MethodChannel-facing adapter for NativeSeedCustodyCore, free of Flutter types so it runs on the JVM. A host (MainActivity, primary-owned)
// would only forward (method, arguments) from MethodChannel.MethodCallHandler to handle() and map ChannelReply to result.success / result.error:
//
//   channel.setMethodCallHandler { call, result ->
//       when (val r = handler.handle(call.method, call.arguments())) {
//           is ChannelReply.Ok -> result.success(r.value)
//           is ChannelReply.Err -> result.error(r.code, null, null)   // code only: never a message, argument or seed
//           is ChannelReply.NotImplemented -> result.notImplemented()
//       }
//   }
//
// Wire format (Dart side to mirror; same names as Dart CustodyError in upper snake case): arguments are a Map<String, Any?> with owner, entry,
// seedVersion, epoch as Long or Int (never Double or String), algorithm as "sha1"|"sha256"|"sha512", digits, periodSeconds, seed as ByteArray.
// Unknown or missing arguments, wrong types and unknown algorithms are INVALID_INPUT. The seed array is zeroed by the core on every path.
// Nothing is logged here. Not wired into the app; the host must also serialize calls with the sync guard (the core only serializes itself).

sealed class ChannelReply {
    data class Ok(val value: Any?) : ChannelReply()
    data class Err(val code: String) : ChannelReply()
    object NotImplemented : ChannelReply()
}

class NativeCustodyChannelHandler(private val core: NativeSeedCustodyCore) {
    private class Bad : Exception()
    private fun Map<*, *>.str(k: String) = (this[k] as? String) ?: throw Bad()
    private fun Map<*, *>.long(k: String): Long = when (val v = this[k]) { is Long -> v; is Int -> v.toLong(); else -> throw Bad() }
    private fun Map<*, *>.int(k: String): Int { val v = long(k); if (v < Int.MIN_VALUE || v > Int.MAX_VALUE) throw Bad(); return v.toInt() }
    private fun Map<*, *>.exact(vararg keys: String) { if (this.keys != keys.toSet()) throw Bad() }
    private fun Map<*, *>.alg(): TotpCalculator.Algorithm = TotpCalculator.Algorithm.entries.firstOrNull { it.name.lowercase() == this["algorithm"] } ?: throw Bad()
    private fun Map<*, *>.bytes(k: String) = (this[k] as? ByteArray) ?: throw Bad()
    private fun Map<*, *>.map(k: String): Map<*, *> = (this[k] as? Map<*, *>) ?: throw Bad()
    private fun Map<*, *>.idLongs(k: String): Map<String, Long> =
        map(k).entries.associate { (key, v) -> (key as? String ?: throw Bad()) to (when (v) { is Long -> v; is Int -> v.toLong(); else -> throw Bad() }) }

    private val known = setOf("readOwnerState", "capability", "provision", "generate", "delete", "clearOwner", "purgeOwner", "readCatalog", "enableOwner", "purgePending", "sweepOrphans", "reconcile")
    fun handle(method: String, arguments: Any?): ChannelReply {
        if (method !in known) { ((arguments as? Map<*, *>)?.get("seed") as? ByteArray)?.fill(0); return ChannelReply.NotImplemented }
        val seed = (arguments as? Map<*, *>)?.get("seed") as? ByteArray
        return try {
            val a = arguments as? Map<*, *> ?: if (method == "capability" || method == "purgePending" || method == "sweepOrphans") emptyMap<Any, Any>() else throw Bad()
            when (method) {
                "capability", "purgePending", "sweepOrphans" -> a.exact()
                "readOwnerState", "readCatalog" -> a.exact("owner")
                "provision" -> a.exact("owner", "entry", "seedVersion", "algorithm", "digits", "periodSeconds", "seed", "epoch")
                "generate" -> a.exact("owner", "entry", "seedVersion", "unixSeconds")
                "delete" -> a.exact("owner", "entry", "seedVersion")
                "clearOwner", "purgeOwner", "enableOwner" -> a.exact("owner", "epoch")
                "reconcile" -> { a.exact("owner", "snapshot"); a.map("snapshot").exact("epoch", "revision", "complete", "versions", "tombstones") }
            }
            when (method) {
                "readOwnerState" -> core.readOwnerState(a.str("owner")).let { ChannelReply.Ok(mapOf("epoch" to it.epoch, "enabled" to it.enabled)) }
                "capability" -> core.capability().let { ChannelReply.Ok(mapOf("protection" to it.protection.name, "reason" to it.reason)) }
                "provision" -> { core.provision(a.str("owner"), a.str("entry"), a.long("seedVersion"), a.alg(), a.int("digits"), a.int("periodSeconds"), a.bytes("seed"), a.long("epoch")); ChannelReply.Ok(null) }
                "generate" -> ChannelReply.Ok(core.generate(a.str("owner"), a.str("entry"), a.long("seedVersion"), a.long("unixSeconds")))
                "delete" -> { core.delete(a.str("owner"), a.str("entry"), a.long("seedVersion")); ChannelReply.Ok(null) }
                "clearOwner" -> ChannelReply.Ok(mapOf("denied" to true, "purged" to core.clearOwner(a.str("owner"), a.long("epoch")).purged))
                "purgeOwner" -> core.purgeOwner(a.str("owner"), a.long("epoch")).let { ChannelReply.Ok(mapOf("purged" to it.purged, "epoch" to it.epoch)) }
                "readCatalog" -> core.readCatalog(a.str("owner")).let { c ->
                    ChannelReply.Ok(mapOf("epoch" to c.epoch, "enabled" to c.enabled, "pendingPurge" to c.pendingPurge, "entries" to c.entries.map {
                        mapOf("entry" to it.entry, "seedVersion" to it.version, "epoch" to it.epoch, "algorithm" to it.algorithm.name.lowercase(), "digits" to it.digits.toLong(),
                            "periodSeconds" to it.period.toLong(), "protection" to it.level, "floor" to it.floor, "minAcceptedVersion" to it.minAccept)
                    }))
                }
                "enableOwner" -> { core.enableOwner(a.str("owner"), a.long("epoch")); ChannelReply.Ok(null) }
                "purgePending" -> ChannelReply.Ok(core.purgePending())
                "sweepOrphans" -> ChannelReply.Ok(core.sweepOrphans().size)
                "reconcile" -> {
                    val snap = a.map("snapshot")
                    val complete = snap["complete"] as? Boolean ?: throw Bad()
                    val r = core.reconcile(a.str("owner"), Snapshot(snap.long("epoch"), snap.long("revision"), complete, snap.idLongs("versions"), snap.idLongs("tombstones")))
                    ChannelReply.Ok(mapOf("removed" to r.removed, "superseded" to r.superseded, "needsProvision" to r.needsProvision, "pendingPurge" to r.pendingPurge))
                }
                else -> ChannelReply.NotImplemented
            }
        } catch (e: CustodyFailure) { ChannelReply.Err(e.error.name) }
        catch (_: Bad) { ChannelReply.Err(CustodyError.INVALID_INPUT.name) }
        finally { seed?.fill(0) }
    }
}
