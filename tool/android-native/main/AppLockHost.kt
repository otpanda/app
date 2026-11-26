package app.otpanda
import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.CancellationSignal
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Local UI protection only. Not server proof, never uses a session renewal key. */
object AppLockHost {
    private var pending=false
    private var verifiedAt=0L
    fun protect(activity:Activity){
        if(activity.getSharedPreferences("otpanda_local_lock",Context.MODE_PRIVATE).getBoolean("enabled",false))
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }
    fun register(activity:Activity,messenger:BinaryMessenger){
        val prefs=activity.getSharedPreferences("otpanda_local_lock",Context.MODE_PRIVATE)
        protect(activity)
        MethodChannel(messenger,"app.otpanda/app-lock").setMethodCallHandler{call,result->
            when(call.method){
                "enabled"->result.success(prefs.getBoolean("enabled",false))
                "verify"->{
                    if(Build.VERSION.SDK_INT<30){result.error("unsupported_os",null,null);return@setMethodCallHandler}
                    if(pending){result.error("busy",null,null);return@setMethodCallHandler}
                    val manager=activity.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
                    if(!manager.isDeviceSecure){result.error("no_secure_lock",null,null);return@setMethodCallHandler}
                    pending=true;verifiedAt=0L
                    try{BiometricPrompt.Builder(activity).setTitle("Unlock OTPanda")
                        .setDescription("Use biometrics or your phone's screen lock.")
                        .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL)
                        .build().authenticate(CancellationSignal(),activity.mainExecutor,object:BiometricPrompt.AuthenticationCallback(){
                            override fun onAuthenticationError(code:Int,message:CharSequence){pending=false;result.error("not_verified",null,null)}
                            override fun onAuthenticationSucceeded(value:BiometricPrompt.AuthenticationResult){pending=false;verifiedAt=android.os.SystemClock.elapsedRealtime();result.success(true)}
                        })
                    }catch(e:Exception){pending=false;result.error("unavailable",null,null)}
                }
                "setEnabled"->{
                    val elapsed=android.os.SystemClock.elapsedRealtime()-verifiedAt
                    if(verifiedAt==0L||elapsed !in 0..15000){result.error("verification_required",null,null);return@setMethodCallHandler}
                    verifiedAt=0L
                    val enabled=call.argument<Boolean>("enabled")==true
                    if(!prefs.edit().putBoolean("enabled",enabled).commit())result.error("storage",null,null)
                    else{if(enabled)activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)else activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE);result.success(null)}
                }
                else->result.notImplemented()
            }
        }
    }
}
