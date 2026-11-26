package org.otpanda.totp.fixture

import android.app.Instrumentation
import android.os.Bundle
import org.otpanda.totp.Fixture

// DEBUG/TEST ONLY instrumentation for the fixture APK. Not part of the app. Usage: am instrument -w -e phase <name> org.otpanda.totp.fixture/.FixtureRunner
class FixtureRunner : Instrumentation() {
    private var phase = ""
    override fun onCreate(arguments: Bundle?) { phase = arguments?.getString("phase") ?: ""; super.onCreate(arguments); start() }
    override fun onStart() {
        var code = 0
        fun emit(line: String) { sendStatus(0, Bundle().apply { putString("stream", line + "\n") }) }
        try { Fixture(targetContext, ::emit).run(phase) }
        catch (e: Throwable) { code = 1; emit("FIXTURE api=${android.os.Build.VERSION.SDK_INT} FAIL ${e.javaClass.simpleName}: ${e.message}") }
        finish(if (code == 0) -1 else 1, Bundle())
    }
}
