package org.otpanda.wrappingkey.fixture

import android.app.Instrumentation
import android.os.Bundle

// DEBUG/TEST ONLY instrumentation for the wrapping-key fixture APK. Not part of the app.
// Usage: am instrument -w -e phase <name> org.otpanda.wrappingkey.fixture/.FixtureRunner
class FixtureRunner : Instrumentation() {
    private var phase = ""
    override fun onCreate(arguments: Bundle?) { phase = arguments?.getString("phase") ?: ""; super.onCreate(arguments); start() }
    override fun onStart() {
        var code = 0
        fun emit(line: String) { sendStatus(0, Bundle().apply { putString("stream", line + "\n") }) }
        try { WrappingKeyFixture(targetContext, ::emit).run(phase) }
        catch (e: Throwable) { code = 1; emit("FIXTURE api=${android.os.Build.VERSION.SDK_INT} FAIL ${e.javaClass.simpleName.replace("Exception", "Exc")}: ${(e.message ?: "").take(100)}") }
        finish(if (code == 0) -1 else 1, Bundle())
    }
}
