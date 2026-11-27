package app.otpanda

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import org.otpanda.documentimport.ImportReply
import org.otpanda.documentimport.ImportController
import java.util.concurrent.Executors

/**
 * Channel "app.otpanda/import-file": pickImportFile -> String (the file as strict UTF-8, at most 2 MiB) | null (user backed
 * out or the request was cancelled); cancelImportFile -> null. Errors: tooLarge | notText | unreadable | busy | unavailable,
 * no message and no details. Both calls take no arguments.
 *
 * The system picker is ACTION_OPEN_DOCUMENT with CATEGORY_OPENABLE and every type (some file managers label .json and .csv
 * as octet-stream). The grant is for this one read only: no persistable permission is requested, the URI is never stored,
 * and nothing is logged. Registered as an engine plugin so it receives the picker result without editing MainActivity's
 * onActivityResult. Not wired into Dart until the primary composes it.
 */
class ImportPickerHost : FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private var binding: ActivityPluginBinding? = null
    private var channel: MethodChannel? = null
    private val session = ImportController(
        startActivity = ::startPicker,
        worker = worker,
        post = { main.post(it) },
    )

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(b.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(::onCall) }
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        session.retire()
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onAttachedToActivity(b: ActivityPluginBinding) { binding = b; b.addActivityResultListener(this) }
    // Rotation and similar: the request and the picker both survive, the result comes to the new activity.
    override fun onDetachedFromActivityForConfigChanges() { binding?.removeActivityResultListener(this); binding = null }
    override fun onReattachedToActivityForConfigChanges(b: ActivityPluginBinding) { binding = b; b.addActivityResultListener(this) }
    // The activity is gone for good: nothing can receive the result. Backgrounding (the picker itself is another activity, so
    // this app pauses and may stop) never reaches here and is deliberately not treated as cancellation.
    override fun onDetachedFromActivity() { binding?.removeActivityResultListener(this); binding = null; session.retire() }

    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.arguments != null) { result.error("unavailable", null, null); return }
        when (call.method) {
            "pickImportFile" -> session.begin(object : ImportReply {
                override fun text(value: String) = result.success(value)
                override fun cancelled() = result.success(null)
                override fun error(code: String) = result.error(code, null, null)
            })
            "cancelImportFile" -> { session.cancel(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    private fun startPicker(code: Int): Boolean {
        val activity: Activity = binding?.activity ?: return false
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*")
        return try {
            activity.startActivityForResult(intent, code)
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: SecurityException) {
            false
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        // Codes are per launch (see PickerRequests); a result from an older launch is consumed and dropped unread.
        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        val activity = binding?.activity
        if (uri == null || activity == null) return session.onResult(requestCode, null)
        val resolver = activity.applicationContext.contentResolver
        return session.onResult(requestCode) { resolver.openInputStream(uri) }
    }

    companion object {
        const val CHANNEL = "app.otpanda/import-file"
        /** One line in MainActivity.configureFlutterEngine, after the other hosts. */
        fun register(engine: FlutterEngine) { engine.plugins.add(ImportPickerHost()) }
    }
}
