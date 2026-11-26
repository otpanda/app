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
    private var generation=0
    private var pending=false
    private var verifiedAt=0L
    private var cancellation:CancellationSignal?=null
    fun reset(){generation++;cancellation?.cancel();cancellation=null;pending=false;verifiedAt=0L}
    private fun flag(activity:Activity)=java.io.File(activity.noBackupFilesDir,"local-app-lock-v1")
    private fun enabled(activity:Activity)=flag(activity).exists()
    fun protect(activity:Activity){
        if(enabled(activity))
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }
    fun register(activity:Activity,messenger:BinaryMessenger){
        reset()
        protect(activity)
        MethodChannel(messenger,"app.otpanda/app-lock").setMethodCallHandler{call,result->
            when(call.method){
                "enabled"->result.success(enabled(activity))
                "verify"->{
                    if(Build.VERSION.SDK_INT<30){result.error("unsupported_os",null,null);return@setMethodCallHandler}
                    if(pending){result.error("busy",null,null);return@setMethodCallHandler}
                    val manager=activity.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
                    if(!manager.isDeviceSecure){result.error("no_secure_lock",null,null);return@setMethodCallHandler}
                    val ownGeneration=generation
                    pending=true;verifiedAt=0L
                    val signal=CancellationSignal();cancellation=signal
                    try{BiometricPrompt.Builder(activity).setTitle("Unlock OTPanda")
                        .setDescription("Use biometrics or your phone's screen lock.")
                        .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL)
                        .build().authenticate(signal,activity.mainExecutor,object:BiometricPrompt.AuthenticationCallback(){
                            override fun onAuthenticationError(code:Int,message:CharSequence){if(ownGeneration!=generation)return;pending=false;cancellation=null;result.error("not_verified",null,null)}
                            override fun onAuthenticationSucceeded(value:BiometricPrompt.AuthenticationResult){if(ownGeneration!=generation)return;pending=false;cancellation=null;verifiedAt=android.os.SystemClock.elapsedRealtime();result.success(true)}
                        })
                    }catch(e:Exception){pending=false;result.error("unavailable",null,null)}
                }
                // Dart calls this only after the server consumed a fresh exact-intent
                // passkey ceremony bound to this device and local lock generation.
                "disableAfterPasskey"->{
                    reset()
                    try{if(flag(activity).exists()&&!flag(activity).delete())throw IllegalStateException();activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE);result.success(null)}catch(e:Exception){result.error("storage",null,null)}
                }
                "setEnabled"->{
                    val elapsed=android.os.SystemClock.elapsedRealtime()-verifiedAt
                    if(verifiedAt==0L||elapsed !in 0..15000){result.error("verification_required",null,null);return@setMethodCallHandler}
                    verifiedAt=0L
                    val enabled=call.argument<Boolean>("enabled")==true
                    try{if(enabled){val f=flag(activity);if(!f.exists()&&!f.createNewFile())throw IllegalStateException()}else if(flag(activity).exists()&&!flag(activity).delete())throw IllegalStateException();
                    if(enabled)activity.window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)else activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE);result.success(null)}catch(e:Exception){result.error("storage",null,null)}
                }
                else->result.notImplemented()
            }
        }
    }
}
