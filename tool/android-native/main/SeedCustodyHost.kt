package app.otpanda

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.otpanda.totp.*
import java.util.concurrent.Executors

/** Composed local adapters (seed custody, seed sync and workspace admission on one worker). Registration alone does not enroll, fetch, provision
 * or select an account. Production MainActivity registers this host after the
 * synthetic installed cold-workspace qualification on API34. One worker/core pair spans engine recreation in this process.
 */
object SeedCustodyHost {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private class State(context: Context) {
        val custody = NativeSeedCustodyCore(AndroidSeedVault(), OwnerStateFileStore(context))
        val custodyChannel = NativeCustodyChannelHandler(custody)
        val installIds = NoBackupInstallIdStore(context)
        val sync = SeedSyncChannelHandler(
            SeedSyncKeyCore(AndroidSyncKeyVault(), SeedSyncStateFileStore(context), custody),
            custody, System::currentTimeMillis,
            installIds = installIds,
        )
        // Workspace admission shares this worker, the custody core and the install id store. It stores no secret and never touches the database or its key.
        val admission = WorkspaceAdmissionChannelHandler(
            WorkspaceAdmissionCore(
                AndroidWorkspaceAdmissionDocs(context), NoBackupWorkspaceCanary(context), installIds,
                custody::readOwnerState, androidWorkspacePathFor(context), ::newCanaryId, androidPrepareWorkspaceDir(context),
            ),
        )
        fun handle(method: String, args: Any?): ChannelReply =
            if (method.startsWith("sync")) sync.handle(method, args)
            else custodyChannel.handle(method, args)
    }
    // Only worker accesses state. The application context never retains Activity.
    private var state: State? = null

    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        MethodChannel(messenger, "app.otpanda/seed-custody").setMethodCallHandler { call, result ->
            dispatch(app, call.method, call.arguments(), result) { st, m, a -> st.handle(m, a) }
        }
        MethodChannel(messenger, "app.otpanda/workspace-admission").setMethodCallHandler { call, result ->
            dispatch(app, call.method, call.arguments(), result) { st, m, a -> st.admission.handle(m, a) }
        }
    }

    private fun dispatch(app: Context, method: String, arguments: Any?, result: MethodChannel.Result, run: (State, String, Any?) -> ChannelReply) {
        if (Build.VERSION.SDK_INT < 30) {
            ((arguments as? Map<*, *>)?.get("seed") as? ByteArray)?.fill(0)
            result.error("UNAVAILABLE", null, null)
            return
        }
        worker.execute {
            val reply = try {
                val current = state ?: State(app).also { state = it }
                run(current, method, arguments)
            } catch (_: Throwable) {
                ((arguments as? Map<*, *>)?.get("seed") as? ByteArray)?.fill(0)
                ChannelReply.Err("UNAVAILABLE")
            }
            main.post {
                when (reply) {
                    is ChannelReply.Ok -> result.success(reply.value)
                    is ChannelReply.Err -> result.error(reply.code, null, null)
                    is ChannelReply.NotImplemented -> result.notImplemented()
                }
            }
        }
    }
}
