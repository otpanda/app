package org.otpanda.totp

import android.content.Context
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.IOException

/** Opens the directory, fsyncs it and closes it with the platform calls. Any errno becomes an IOException so the caller fails closed. UNVERIFIED on a device. */
class AndroidDirSync : DirSync {
    override fun sync(dir: File) {
        val fd = try { Os.open(dir.path, OsConstants.O_RDONLY, 0) } catch (e: ErrnoException) { throw IOException("open failed") }
        try { Os.fsync(fd) } catch (e: ErrnoException) { throw IOException("fsync failed") }
        finally { try { Os.close(fd) } catch (_: ErrnoException) { } }
    }
}

/** The install id under noBackupFilesDir in its own directory: excluded from backup, never cleared by logout, owner switch or session reset. Not wired into the app host. */
class NoBackupInstallIdStore(context: Context) : InstallIdStore by InstallIdFile(File(context.noBackupFilesDir, "otpanda-install-v1"), AndroidDirSync())
