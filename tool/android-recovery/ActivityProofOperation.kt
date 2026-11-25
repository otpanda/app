package org.otpanda.recovery

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.os.CancellationSignal
import java.util.concurrent.atomic.AtomicBoolean

/** Owned by one foreground Activity, never a background recovery keepalive. */
class ActivityProofOperation(private val activity: Activity, private val keys: DurableDeviceKey) {
    private val active = AtomicBoolean(false)
    private var generation = 0
    private var cancellation: CancellationSignal? = null
    private var completion: ((Result<ByteArray>) -> Unit)? = null
    private var listener: Application.ActivityLifecycleCallbacks? = null

    /** Call on the main thread. Lifecycle cancellation suppresses all late data. */
    fun start(proof: DeviceProof, displayText: String? = null, complete: (Result<ByteArray>) -> Unit) {
        check(android.os.Looper.myLooper() == android.os.Looper.getMainLooper())
        check(!activity.isFinishing && !activity.isDestroyed)
        check(active.compareAndSet(false,true))
        val attempt = ++generation
        completion = complete
        val callback = object: Application.ActivityLifecycleCallbacks {
            override fun onActivityStopped(a: Activity) { if (a === activity) cancel() }
            override fun onActivityDestroyed(a: Activity) { if (a === activity) cancel() }
            override fun onActivityCreated(a: Activity, saved: Bundle?) {}
            override fun onActivityStarted(a: Activity) {}
            override fun onActivityResumed(a: Activity) {}
            override fun onActivityPaused(a: Activity) {}
            override fun onActivitySaveInstanceState(a: Activity, saved: Bundle) {}
        }
        listener = callback
        activity.application.registerActivityLifecycleCallbacks(callback)
        try {
            val operation = keys.signWithOsVerification(activity, proof, displayText = displayText) { result ->
                if (attempt == generation && active.compareAndSet(true,false)) {
                    detach(); complete(result)
                } else { result.getOrNull()?.fill(0) }
            }
            if (attempt == generation && active.get()) cancellation = operation
            else operation.cancel()
        } catch(error: Exception) {
            if (attempt == generation) { active.set(false); detach(); complete(Result.failure(error)) }
        }
    }
    fun cancel() {
        check(android.os.Looper.myLooper() == android.os.Looper.getMainLooper())
        generation++
        val wasActive = active.getAndSet(false)
        val operation = cancellation
        val reply = completion
        detach()
        operation?.cancel()
        if (wasActive) reply?.invoke(Result.failure(DeviceProofException("cancelled")))
    }
    private fun detach() {
        listener?.let { activity.application.unregisterActivityLifecycleCallbacks(it) }
        listener = null; cancellation = null; completion = null
    }
}
