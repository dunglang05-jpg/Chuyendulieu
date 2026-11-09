// Phone Transfer Pro — Android platform adapter. NOT YET BUILT OR DEVICE-TESTED (see docs/STATUS.md).
package com.phonetransferpro.ptp_platform

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.os.StatFs
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import com.phonetransferpro.ptp_platform.usb.UsbTransport
import java.io.File

class PtpPlatformPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.RequestPermissionsResultListener, PluginRegistry.ActivityResultListener {

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activity: Activity? = null
    private var binding: ActivityPluginBinding? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var media: MediaAdapter
    private lateinit var contacts: ContactsAdapter
    private lateinit var usbTransport: UsbTransport
    private lateinit var vault: SecureVault
    private lateinit var hotspot: Hotspot

    private var pendingPermission: Pair<Int, MethodChannel.Result>? = null
    private var pendingPermissionCategory: String? = null
    private var pendingPick: MethodChannel.Result? = null
    private var pendingPickCategory: String = "documents"

    override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
        context = b.applicationContext
        media = MediaAdapter(context)
        vault = SecureVault(context)
        contacts = ContactsAdapter(context)
        usbTransport = UsbTransport(context)
        hotspot = Hotspot(context)
        channel = MethodChannel(b.binaryMessenger, "com.phonetransferpro/ptp_platform")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        media.closeAll()
        usbTransport.stop()
        hotspot.stop()
        hotspot.leave()
        scope.cancel()
    }

    override fun onAttachedToActivity(b: ActivityPluginBinding) {
        activity = b.activity
        binding = b
        b.addRequestPermissionsResultListener(this)
        b.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        binding?.removeRequestPermissionsResultListener(this)
        binding?.removeActivityResultListener(this)
        activity = null
        binding = null
    }

    override fun onReattachedToActivityForConfigChanges(b: ActivityPluginBinding) = onAttachedToActivity(b)
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    /** Runs [block] on IO and answers on the main thread. Never logs file names or content. */
    private fun io(result: MethodChannel.Result, block: suspend () -> Any?) {
        scope.launch {
            try {
                val v = block()
                withContext(Dispatchers.Main) { result.success(v) }
            } catch (e: SecurityException) {
                withContext(Dispatchers.Main) { result.error("PERMISSION_DENIED", e.javaClass.simpleName, null) }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) { result.error("INTERNAL_ERROR", e.javaClass.simpleName, null) }
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "probe" -> io(result) { probe() }
            "requestPermission" -> requestPermission(call.argument<String>("category")!!, call.argument<Boolean>("forImport") ?: false, result)
            "scan" -> io(result) {
                val cat = call.argument<String>("category")!!
                val limit = call.argument<Int>("limit") ?: 100000
                if (cat == "contacts") contacts.scan() else media.scan(cat, limit)
            }
            "pickDocuments" -> pickDocuments(call.argument<String>("category") ?: "documents", result)
            "openForRead" -> io(result) {
                val id = call.argument<String>("id")!!
                if (id == ContactsAdapter.ALL_CONTACTS_ID) media.openFile(contacts.exportAll(File(context.cacheDir, "export")))
                else media.openForRead(Uri.parse(id))
            }
            "closeRead" -> io(result) { media.closeRead(call.argument<String>("token")!!); null }
            "inboxDir" -> result.success(File(context.filesDir, "inbox").apply { mkdirs() }.absolutePath)
            "freeBytes" -> io(result) { StatFs(call.argument<String>("path")!!).availableBytes }
            "importFile" -> io(result) {
                val path = call.argument<String>("path")!!
                val cat = call.argument<String>("category")!!
                val name = call.argument<String>("name")!!
                val mime = call.argument<String>("mime")
                if (cat == "contacts") contacts.importViaSystemApp(activity, File(path)) else media.importFile(File(path), cat, name, mime)
            }
            // Receive straight into MediaStore (audit P1-7). NOT TESTED ON DEVICES.
            "mediaCreate" -> io(result) {
                media.createPending(call.argument<String>("category")!!, call.argument<String>("name")!!, call.argument<String>("mime"))
            }
            // Continuation key (audit P1-10), sealed by Android Keystore. NOT TESTED ON DEVICES.
            "vaultPut" -> io(result) {
                vault.put(call.argument<String>("name")!!, android.util.Base64.decode(call.argument<String>("data")!!, android.util.Base64.NO_WRAP))
                null
            }
            "vaultGet" -> io(result) {
                vault.get(call.argument<String>("name")!!)?.let { android.util.Base64.encodeToString(it, android.util.Base64.NO_WRAP) }
            }
            "vaultDelete" -> io(result) { vault.delete(call.argument<String>("name")!!); null }
            "mediaReopen" -> io(result) { media.reopenPending(call.argument<String>("uri")!!) }
            "mediaPublish" -> io(result) { media.publishPending(call.argument<String>("uri")!!) }
            "mediaDelete" -> io(result) { media.deletePending(call.argument<String>("uri")!!); null }
            "setTransferActive" -> {
                TransferService.setActive(context, call.argument<Boolean>("active") ?: false)
                result.success(null)
            }
            "deviceState" -> result.success(deviceState())
            // USB-C Android↔Android link (AOA). See docs/USB_C_OTG_ARCHITECTURE.md. NOT TESTED ON DEVICES.
            "usbStatus" -> result.success(usbTransport.status())
            "usbStart" -> {
                usbTransport.start(
                    call.argument<String>("mode") ?: "listen",
                    call.argument<Int>("port") ?: 0,
                    (call.argument<Number>("timeoutMs")?.toLong() ?: 90_000L).coerceIn(5_000L, 12 * 3_600_000L),
                )
                result.success(usbTransport.status())
            }
            "usbStop" -> {
                usbTransport.stop()
                result.success(null)
            }
            // Run in background with the screen off: battery optimisation status / one-time system request.
            "backgroundStatus" -> {
                val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                result.success(mapOf(
                    "ignoringBatteryOptimizations" to pm.isIgnoringBatteryOptimizations(context.packageName),
                    "manufacturer" to Build.MANUFACTURER.lowercase(),
                ))
            }
            "requestBackground" -> {
                val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
                if (pm.isIgnoringBatteryOptimizations(context.packageName)) {
                    result.success("granted")
                } else {
                    try {
                        @Suppress("BatteryLife")
                        val i = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}"))
                        (activity ?: context).startActivity(if (activity == null) i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) else i)
                        result.success("asked")
                    } catch (e: Exception) {
                        result.success("unavailable")
                    }
                }
            }
            "openBatterySettings" -> {
                try {
                    context.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                } catch (e: Exception) {
                    context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }
                result.success(null)
            }
            // Direct phone-to-phone Wi-Fi ("Điểm phát"). NOT TESTED ON DEVICES. Name/password are never logged.
            "hotspotStart" -> hotspot.start(call.argument<Boolean>("force24") ?: false) { info, err ->
                if (err != null) result.error(err, err, null) else result.success(info)
            }
            "hotspotStop" -> {
                hotspot.stop()
                result.success(null)
            }
            "hotspotJoin" -> hotspot.join(
                call.argument<String>("ssid")!!,
                call.argument<String>("psk")!!,
                call.argument<String>("sec") ?: "wpa2",
                call.argument<String>("mode") ?: "ap",
                call.argument<String>("band") ?: "a",
                (call.argument<Int>("timeoutMs") ?: 60_000).coerceIn(5_000, 180_000),
            ) { gw, err -> if (err != null) result.error(err, err, null) else result.success(gw) }
            "hotspotLeave" -> {
                hotspot.leave()
                result.success(null)
            }
            "wifiLinkMbps" -> result.success(hotspot.linkMbps())
            "openAppSettings" -> {
                val i = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(i)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ------------------------------------------------------------------ capabilities (runtime-probed)
    private fun granted(p: String) = ContextCompat.checkSelfPermission(context, p) == PackageManager.PERMISSION_GRANTED

    private fun mediaPermissions(cat: String): List<String> = when {
        Build.VERSION.SDK_INT >= 33 -> when (cat) {
            "photos" -> listOf(Manifest.permission.READ_MEDIA_IMAGES)
            "videos" -> listOf(Manifest.permission.READ_MEDIA_VIDEO)
            "audio" -> listOf(Manifest.permission.READ_MEDIA_AUDIO)
            else -> emptyList()
        }
        else -> if (cat in listOf("photos", "videos", "audio")) listOf(Manifest.permission.READ_EXTERNAL_STORAGE) else emptyList()
    }

    /** Local-only hotspot / Wi-Fi network request: "Nearby devices" on 13+, location before that. */
    private fun nearbyWifiPermissions(): List<String> =
        if (Build.VERSION.SDK_INT >= 33) listOf(Manifest.permission.NEARBY_WIFI_DEVICES)
        else listOf(Manifest.permission.ACCESS_FINE_LOCATION)

    private fun permissionState(cat: String): String {
        if (cat == "notifications") {
            return if (Build.VERSION.SDK_INT < 33 || granted(Manifest.permission.POST_NOTIFICATIONS)) "granted" else "denied"
        }
        if (cat == "contacts") return if (granted(Manifest.permission.READ_CONTACTS)) "granted" else "denied"
        if (cat == "nearbyWifi") return if (nearbyWifiPermissions().all { granted(it) }) "granted" else "denied"
        val perms = mediaPermissions(cat)
        if (perms.isEmpty()) return "not_applicable"
        if (perms.all { granted(it) }) return "granted"
        if (Build.VERSION.SDK_INT >= 34 && cat != "audio" && granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)) return "limited"
        return "denied"
    }

    private fun probe(): Map<String, Any?> {
        val cats = listOf("photos", "videos", "audio", "documents", "contacts", "calendar")
        val perms = cats.associateWith { permissionState(it) }
        fun exportStatus(c: String) = when (c) {
            "calendar" -> "unsupported"
            "documents" -> "supported"
            else -> if (perms[c] == "granted") "supported" else if (perms[c] == "limited") "partial" else "permission_required"
        }
        fun importStatus(c: String) = when (c) {
            "calendar" -> "unsupported"
            "contacts" -> "official_flow"
            else -> "supported" // writing into our own MediaStore entries needs no permission on API 29+
        }
        val categories = cats.map {
            mapOf("id" to it, "export" to (it != "calendar"), "import" to (it != "calendar"),
                "status" to if (exportStatus(it) == "unsupported") "unsupported" else exportStatus(it),
                "importStatus" to importStatus(it))
        }
        return mapOf(
            "platform" to "android",
            "osVersion" to "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
            "model" to "${Build.MANUFACTURER} ${Build.MODEL}",
            "deviceName" to (Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME) ?: Build.MODEL),
            "freeBytes" to StatFs(context.filesDir.absolutePath).availableBytes,
            "backgroundConstraints" to "foreground_service",
            "permissions" to perms,
            "categories" to categories,
        )
    }

    // ------------------------------------------------------------------ permissions, asked in context
    private fun requestPermission(cat: String, forImport: Boolean, result: MethodChannel.Result) {
        val act = activity ?: return result.error("INTERNAL_ERROR", "no activity", null)
        if (forImport && cat != "contacts") return result.success("granted") // own MediaStore inserts need none
        val perms = when (cat) {
            "notifications" -> if (Build.VERSION.SDK_INT >= 33) listOf(Manifest.permission.POST_NOTIFICATIONS) else emptyList()
            "nearbyWifi" -> nearbyWifiPermissions()
            "contacts" -> if (forImport) emptyList() else listOf(Manifest.permission.READ_CONTACTS)
            else -> mediaPermissions(cat).toMutableList().apply {
                if (Build.VERSION.SDK_INT >= 34 && cat != "audio") add(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
            }
        }
        if (perms.isEmpty() || perms.all { granted(it) }) return result.success("granted")
        pendingPermission?.second?.error("INTERNAL_ERROR", "superseded", null)
        val code = 0x5054 + (System.nanoTime() and 0xFF).toInt()
        pendingPermission = code to result
        pendingPermissionCategory = cat
        ActivityCompat.requestPermissions(act, perms.toTypedArray(), code)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        val pending = pendingPermission ?: return false
        if (pending.first != requestCode) return false
        pendingPermission = null
        pending.second.success(permissionState(pendingPermissionCategory ?: ""))
        return true
    }

    // ------------------------------------------------------------------ Storage Access Framework picker
    private fun pickDocuments(cat: String, result: MethodChannel.Result) {
        val act = activity ?: return result.error("INTERNAL_ERROR", "no activity", null)
        pendingPick?.error("INTERNAL_ERROR", "superseded", null)
        pendingPick = result
        pendingPickCategory = cat
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = if (cat == "audio") "audio/*" else "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        act.startActivityForResult(intent, PICK_CODE)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_CODE) return false
        val result = pendingPick ?: return true
        pendingPick = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(emptyList<Any>())
            return true
        }
        val uris = mutableListOf<Uri>()
        data.clipData?.let { clip -> for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri) }
        if (uris.isEmpty()) data.data?.let { uris.add(it) }
        io(result) { uris.map { media.describeDocument(it, pendingPickCategory) } }
        return true
    }

    private fun deviceState(): Map<String, Any?> {
        val bm = context.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val thermal = when (pm.currentThermalStatus) {
            PowerManager.THERMAL_STATUS_NONE, PowerManager.THERMAL_STATUS_LIGHT -> "nominal"
            PowerManager.THERMAL_STATUS_MODERATE -> "fair"
            PowerManager.THERMAL_STATUS_SEVERE -> "serious"
            else -> "critical"
        }
        return mapOf(
            "batteryPct" to bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY),
            "charging" to bm.isCharging,
            "thermal" to thermal,
        )
    }

    companion object {
        private const val PICK_CODE = 0x5055
    }
}
