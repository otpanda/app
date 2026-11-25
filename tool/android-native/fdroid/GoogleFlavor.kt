package app.otpanda

import android.app.Activity
import io.flutter.plugin.common.BinaryMessenger

/** F-Droid flavor: no Google or Play Services code. Native Google is absent. */
object GoogleFlavor {
    fun register(activity: Activity, messenger: BinaryMessenger) {}
}
