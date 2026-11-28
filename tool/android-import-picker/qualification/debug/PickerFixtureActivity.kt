package app.otpanda.pickerfx

import android.os.Bundle
import android.util.Log
import app.otpanda.ImportPickerHost
import app.otpanda.MainActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

/**
 * Debug source set only. Extends the real MainActivity (real engine and lifecycle) and registers the PRODUCTION ImportPickerHost
 * itself unless the app already registered it. The driver channel is fixture-only: scenario and phase, fixed-label logging,
 * lifecycle counters, recreate(). No file content, URI or name is ever logged.
 */
class PickerFixtureActivity : MainActivity() {
    private val phaseFile get() = File(noBackupFilesDir, "pickfx-phase")

    override fun onCreate(savedInstanceState: Bundle?) {
        val n = creates.incrementAndGet()
        // A fresh start (not a system recreation or restore) resets the persisted phase.
        if (savedInstanceState == null && intent.getBooleanExtra("fresh", false)) phaseFile.delete()
        Log.i(TAG, "ACT create $n restored ${savedInstanceState != null}")
        super.onCreate(savedInstanceState)
    }

    override fun onStop() { Log.i(TAG, "ACT stop ${stops.incrementAndGet()}"); super.onStop() }
    override fun onDestroy() { Log.i(TAG, "ACT destroy finishing ${isFinishing}"); super.onDestroy() }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        Log.i(TAG, "ENGINE cleanup ${cleanups.incrementAndGet()}")
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        Log.i(TAG, "ENGINE configure ${configures.incrementAndGet()}")
        if (!engine.plugins.has(ImportPickerHost::class.java)) ImportPickerHost.register(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "pickfx/driver").setMethodCallHandler { call, result ->
            when (call.method) {
                "config" -> result.success(mapOf(
                    "scenario" to (intent.getStringExtra("scenario") ?: "none"),
                    "phase" to (if (phaseFile.exists()) phaseFile.readText() else "start"),
                ))
                "setPhase" -> {
                    val p = call.argument<String>("phase")
                    if (p != null && p.matches(LABEL)) { phaseFile.writeText(p); result.success(null) } else result.error("FIXTURE", null, null)
                }
                "stopCount" -> result.success(stops.get())
                "recreate" -> { runOnUiThread { recreate() }; result.success(null) }
                "mark", "log" -> {
                    val label = call.argument<String>("label") ?: "missing"
                    if (!label.matches(LABEL)) result.error("FIXTURE", null, null) else {
                        if (call.method == "mark") Log.i(TAG, "MARK $label")
                        else Log.i(TAG, "CHECK $label ${call.argument<Boolean>("ok") == true}")
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    companion object {
        const val TAG = "PICKFX"
        private val LABEL = Regex("[a-z0-9_]{1,64}")
        private val creates = AtomicInteger()
        private val stops = AtomicInteger()
        private val configures = AtomicInteger()
        private val cleanups = AtomicInteger()
    }
}
