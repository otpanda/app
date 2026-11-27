package app.otpanda

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.otpanda.wrappingkey.*
import java.util.concurrent.Executors

/** Channel "app.otpanda/wrapping-key" for the offline-cache wrapping key. Registration alone creates no key and reads nothing. One worker and one core span engine
 * recreation in this process. Replies carry only a code and {outcomeUnknown}; never a message, namespace or key in an error. The application context never retains an Activity. */
object WrappingKeyHost {
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var handler: WrappingKeyChannelHandler? = null // only the worker touches it

    fun register(context: Context, messenger: BinaryMessenger) {
        val app = context.applicationContext
        MethodChannel(messenger, "app.otpanda/wrapping-key").setMethodCallHandler { call, result ->
            val method = call.method
            val args = call.arguments
            worker.execute {
                val reply = try {
                    val h = handler ?: WrappingKeyChannelHandler(androidWrappingKeyCore(app)).also { handler = it }
                    h.handle(method, args)
                } catch (_: Throwable) {
                    (((args as? Map<*, *>)?.get("key")) as? ByteArray)?.fill(0)
                    WkReply.Err("unavailable", method != "wrappingKeyRead")
                }
                main.post {
                    when (reply) {
                        is WkReply.Ok -> result.success(reply.value)
                        is WkReply.Err -> result.error(reply.code, null, mapOf("outcomeUnknown" to reply.outcomeUnknown))
                        is WkReply.NotImplemented -> result.notImplemented()
                    }
                }
            }
        }
    }
}
