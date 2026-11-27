package org.otpanda.wrappingkey.fixture

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import org.otpanda.wrappingkey.*
import java.io.File
import java.security.MessageDigest

// DEBUG/TEST ONLY. Each service runs in its own OS process (see the manifest) with the same app UID, files and Keystore as the instrumentation process,
// so concurrent creation and crash recovery cross real process boundaries. They only write result files under noBackupFilesDir.

internal fun sha16(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).take(8).joinToString("") { "%02x".format(it) }
internal fun stateFile(ctx: Context, name: String) = File(ctx.noBackupFilesDir, "fx-wk-$name")
internal fun writeAtomic(f: File, text: String) { val t = File(f.path + ".tmp"); t.writeText(text); check(t.renameTo(f)) }
internal const val RACE_NS = "fx-race"
internal const val CRASH_NS = "fx-crash"

abstract class RaceService(private val n: Int) : Service() {
    override fun onBind(i: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val app = applicationContext
        val t0 = intent?.getLongExtra("t0", 0) ?: 0
        val cand = ByteArray(32) { (n * 16 + 1).toByte() }
        Thread {
            while (System.currentTimeMillis() < t0) Thread.sleep(1)
            var tries = 8
            var line: String
            while (true) {
                try { val r = androidWrappingKeyCore(app).createIfAbsent(RACE_NS, cand); line = "key=${sha16(r.first)} created=${r.second}"; break }
                catch (e: WrappingKeyFailure) { if (--tries <= 0) { line = "FAILED ${e.kind.name} unknown=${e.outcomeUnknown}"; break }; Thread.sleep(60) }
                catch (e: Throwable) { line = "FAILED ${e.javaClass.simpleName.replace("Exception", "Exc")}"; break }
            }
            writeAtomic(stateFile(app, "race-$n.txt"), line)
            stopSelf()
        }.start()
        return START_NOT_STICKY
    }
}
class RaceService1 : RaceService(1)
class RaceService2 : RaceService(2)
class RaceService3 : RaceService(3)

/** Starts a create and blocks after the temp file is written and fsynced, then waits to be killed by the instrumentation process. */
class CrashService : Service() {
    override fun onBind(i: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val app = applicationContext
        Thread {
            // Same directory and wiring as production, plus a hook that blocks after the temp file is fsynced.
            val core = WrappingKeyCore(
                dir = File(app.noBackupFilesDir, "otpanda-wrapping-key-v1"), dirSync = AndroidWkDirSync(), wrapperFor = { KeystoreAesGcmWrapper(it) },
                fileSync = { s -> s.fd.sync(); writeAtomic(stateFile(app, "crash-ready.txt"), android.os.Process.myPid().toString()); Thread.sleep(Long.MAX_VALUE) },
            )
            try { core.createIfAbsent(CRASH_NS, ByteArray(32) { 0x77 }) } catch (e: Throwable) { writeAtomic(stateFile(app, "crash-ready.txt"), "FAILED ${e.javaClass.simpleName.replace("Exception", "Exc")}") }
        }.start()
        return START_NOT_STICKY
    }
}
