// Phone Transfer Pro — "Ứng dụng" category (Android → Android). NOT TESTED ON DEVICES (see docs/APPS_TRANSFER.md).
//
// Sender: lists apps the user installed and packs each app's APK files (base + splits) into one ".apks" ZIP.
// APK files of installed apps are readable by any app; app DATA (/data/data/<pkg>) is not and is never touched.
// Receiver: installs each package with PackageInstaller. Android shows its own "Install?" dialog for every app
// (a regular app cannot install silently on first install); nothing is bypassed.
package com.phonetransferpro.ptp_platform

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import java.util.UUID
import java.util.zip.Deflater
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

class AppsAdapter(private val context: Context) {
    private val pm get() = context.packageManager

    // ------------------------------------------------------------------ sender
    @Suppress("DEPRECATION")
    private fun installedApps(): List<ApplicationInfo> =
        if (Build.VERSION.SDK_INT >= 33) pm.getInstalledApplications(PackageManager.ApplicationInfoFlags.of(0))
        else pm.getInstalledApplications(0)

    private fun apkFiles(ai: ApplicationInfo): List<File> =
        (listOf(ai.sourceDir) + (ai.splitSourceDirs?.toList() ?: emptyList())).map { File(it) }

    /** Apps the user installed (not system apps, not this app). No file names or contents leave the phone here. */
    fun scan(): List<Map<String, Any?>> = installedApps()
        .filter { (it.flags and ApplicationInfo.FLAG_SYSTEM) == 0 && it.packageName != context.packageName }
        .mapNotNull { ai ->
            val files = apkFiles(ai)
            if (files.any { !it.canRead() }) return@mapNotNull null
            mapOf(
                "id" to "$PREFIX${ai.packageName}",
                "name" to pm.getApplicationLabel(ai).toString(),
                "relPath" to "Apps/${ai.packageName}.apks",
                "category" to "apps",
                "size" to files.sumOf { it.length() },
                "mime" to "application/zip",
                "packageName" to ai.packageName,
                "splits" to (files.size - 1),
            )
        }
        .sortedBy { (it["name"] as String).lowercase() }

    /** Packs base.apk + split APKs into one ZIP (no compression: APKs are already compressed). */
    fun pack(id: String, stageDir: File): File {
        val pkg = id.removePrefix(PREFIX)
        @Suppress("DEPRECATION")
        val ai = if (Build.VERSION.SDK_INT >= 33) pm.getApplicationInfo(pkg, PackageManager.ApplicationInfoFlags.of(0))
        else pm.getApplicationInfo(pkg, 0)
        stageDir.mkdirs()
        val out = File(stageDir, UUID.randomUUID().toString() + ".apks")
        ZipOutputStream(out.outputStream().buffered(1 shl 20)).use { zip ->
            zip.setLevel(Deflater.NO_COMPRESSION)
            apkFiles(ai).forEachIndexed { i, f ->
                zip.putNextEntry(ZipEntry(if (i == 0) "base.apk" else f.name))
                f.inputStream().use { it.copyTo(zip, 1 shl 20) }
                zip.closeEntry()
            }
        }
        return out
    }

    // ------------------------------------------------------------------ receiver
    private var permissionWait: CompletableDeferred<Unit>? = null

    /** Called by the plugin when the "Install unknown apps" settings screen returns. */
    fun onInstallPermissionResult() {
        permissionWait?.complete(Unit)
    }

    /**
     * Installs one ".apks" package. Returns {status, location?, message?}:
     * imported (installed or already present), requires_user_action (cancelled / permission missing), failed.
     * Deletes the received file afterwards.
     */
    suspend fun install(activity: Activity?, apks: File, launch: suspend (Intent, Int) -> Boolean): Map<String, Any?> {
        try {
            val pkg = apks.name.removeSuffix(".apks").takeIf { PKG.matches(it) }
            if (pkg != null && isInstalled(pkg)) {
                return mapOf("status" to "imported", "location" to pkg, "message" to "ALREADY_INSTALLED")
            }
            if (!pm.canRequestPackageInstalls()) {
                val wait = CompletableDeferred<Unit>()
                permissionWait = wait
                val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
                if (activity == null || !launch(intent, INSTALL_PERMISSION_CODE)) {
                    return mapOf("status" to "requires_user_action", "message" to "INSTALL_PERMISSION")
                }
                withTimeoutOrNull(5 * 60_000L) { wait.await() }
                permissionWait = null
                if (!pm.canRequestPackageInstalls()) {
                    return mapOf("status" to "requires_user_action", "message" to "INSTALL_PERMISSION")
                }
            }
            return installSession(activity, apks, pkg)
        } finally {
            apks.delete()
        }
    }

    private fun isInstalled(pkg: String): Boolean = try {
        @Suppress("DEPRECATION")
        if (Build.VERSION.SDK_INT >= 33) pm.getPackageInfo(pkg, PackageManager.PackageInfoFlags.of(0)) else pm.getPackageInfo(pkg, 0)
        true
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }

    private suspend fun installSession(activity: Activity?, apks: File, pkg: String?): Map<String, Any?> {
        val installer = pm.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            if (pkg != null) setAppPackageName(pkg)
            setInstallReason(PackageManager.INSTALL_REASON_USER)
            if (Build.VERSION.SDK_INT >= 33) setPackageSource(PackageInstaller.PACKAGE_SOURCE_LOCAL_FILE)
        }
        val sessionId = installer.createSession(params)
        val session = installer.openSession(sessionId)
        try {
            var count = 0
            ZipInputStream(apks.inputStream().buffered(1 shl 20)).use { zip ->
                while (true) {
                    val e = zip.nextEntry ?: break
                    val name = e.name
                    // Only flat "*.apk" entries; anything else (paths, other files) is ignored.
                    if (e.isDirectory || name.contains('/') || name.contains('\\') || !name.endsWith(".apk") || name.length > 200) continue
                    session.openWrite(name, 0, -1).use { out ->
                        zip.copyTo(out, 1 shl 20)
                        session.fsync(out)
                    }
                    count++
                }
            }
            if (count == 0) {
                session.abandon()
                return mapOf("status" to "failed", "message" to "NO_APK")
            }
        } catch (e: Exception) {
            session.abandon()
            return mapOf("status" to "failed", "message" to e.javaClass.simpleName)
        }

        val action = "${context.packageName}.ptp.INSTALL_STATUS.$sessionId"
        val events = Channel<Intent>(Channel.UNLIMITED)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                events.trySend(intent)
            }
        }
        ContextCompat.registerReceiver(context, receiver, IntentFilter(action), ContextCompat.RECEIVER_NOT_EXPORTED)
        try {
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
            val pi = PendingIntent.getBroadcast(context, sessionId, Intent(action).setPackage(context.packageName), flags)
            session.commit(pi.intentSender)
            session.close()
            while (true) {
                val intent = withTimeoutOrNull(15 * 60_000L) { events.receive() }
                    ?: return mapOf("status" to "requires_user_action", "message" to "INSTALL_TIMEOUT")
                when (val st = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
                    PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                        @Suppress("DEPRECATION")
                        val confirm = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                        else intent.getParcelableExtra(Intent.EXTRA_INTENT)
                        if (confirm == null) return mapOf("status" to "failed", "message" to "NO_CONFIRM_INTENT")
                        // The system "Install?" dialog. The user decides; we only wait for the result.
                        withContext(Dispatchers.Main) {
                            (activity ?: context).startActivity(
                                if (activity == null) confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) else confirm)
                        }
                    }
                    PackageInstaller.STATUS_SUCCESS ->
                        return mapOf("status" to "imported", "location" to (intent.getStringExtra(PackageInstaller.EXTRA_PACKAGE_NAME) ?: pkg))
                    PackageInstaller.STATUS_FAILURE_ABORTED ->
                        return mapOf("status" to "requires_user_action", "message" to "INSTALL_CANCELLED")
                    else -> return mapOf("status" to "failed", "message" to failureName(st))
                }
            }
        } finally {
            try {
                context.unregisterReceiver(receiver)
            } catch (_: Exception) {
            }
        }
    }

    private fun failureName(st: Int) = when (st) {
        PackageInstaller.STATUS_FAILURE_BLOCKED -> "INSTALL_BLOCKED"
        PackageInstaller.STATUS_FAILURE_CONFLICT -> "INSTALL_CONFLICT" // e.g. same app with another signature
        PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> "INSTALL_INCOMPATIBLE" // CPU/Android version
        PackageInstaller.STATUS_FAILURE_INVALID -> "INSTALL_INVALID"
        PackageInstaller.STATUS_FAILURE_STORAGE -> "INSTALL_STORAGE"
        else -> "INSTALL_FAILED"
    }

    companion object {
        const val PREFIX = "app:"
        const val INSTALL_PERMISSION_CODE = 0x5056
        private val PKG = Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$")
    }
}
