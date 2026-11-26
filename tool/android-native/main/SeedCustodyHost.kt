package app.otpanda

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.otpanda.totp.AndroidSeedVault
import org.otpanda.totp.ChannelReply
import org.otpanda.totp.NativeCustodyChannelHandler
import org.otpanda.totp.NativeSeedCustodyCore
import org.otpanda.totp.OwnerStateFileStore
import java.util.concurrent.Executors

/** Native custody adapter, no network or account selection. Nothing provisions
 * until an authorized sync caller supplies a seed. One core and one worker per
 * process serialize calls across engine recreation. Diagnostics never leave it.
 */
object SeedCustodyHost {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    // Accessed only by worker. The application context never retains an Activity.
    private var handler: NativeCustodyChannelHandler? = null

    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        MethodChannel(messenger, "app.otpanda/seed-custody").setMethodCallHandler { call, result ->
            if (Build.VERSION.SDK_INT < 30) {
                (call.arguments as? Map<*, *>)?.get("seed").let { (it as? ByteArray)?.fill(0) }
                result.error("UNAVAILABLE", null, null)
            } else {
                worker.execute {
                    val reply = try {
                        val h = handler ?: NativeCustodyChannelHandler(
                            NativeSeedCustodyCore(AndroidSeedVault(), OwnerStateFileStore(app))
                        ).also { handler = it }
                        h.handle(call.method, call.arguments)
                    } catch (_: Exception) {
                        (call.arguments as? Map<*, *>)?.get("seed").let { (it as? ByteArray)?.fill(0) }
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
    }
}
