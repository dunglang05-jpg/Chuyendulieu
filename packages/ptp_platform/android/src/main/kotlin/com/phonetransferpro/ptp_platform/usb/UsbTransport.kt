// Android ↔ Android USB transport using the documented Android Open Accessory (AOA) protocol.
// NOT TESTED ON DEVICES (docs/USB_C_OTG_TEST_REPORT.md). Public APIs only: android.hardware.usb.*.
//
// Whichever phone ends up as USB host (the one that sees a UsbDevice — chosen by USB-C role negotiation or by the
// user's "USB controlled by" setting) switches the other phone into accessory mode, then both open the two bulk
// endpoints and run [UsbBridge] over them. This is independent of who shows the QR code.
package com.phonetransferpro.ptp_platform.usb

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.ParcelFileDescriptor
import androidx.core.content.ContextCompat
import java.io.BufferedInputStream
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class UsbTransport(private val context: Context) {
    companion object {
        // Identity strings sent by the host; the accessory side refuses any accessory that does not match.
        const val MANUFACTURER = "PhoneTransferPro"
        const val MODEL = "ChuyenDuLieu"
        private const val DESCRIPTION = "Phone Transfer Pro USB link"
        private const val VERSION = "1"
        private const val URI = "https://github.com/dunglang05-jpg/Chuyendulieu"
        private const val SERIAL = "ptp-usb-1"

        private const val GOOGLE_VID = 0x18D1
        private val AOA_PIDS = 0x2D00..0x2D05 // accessory (+adb/audio variants)
        private const val ACTION_PERMISSION = "com.phonetransferpro.ptp_platform.USB_PERMISSION"
        private const val AOA_GET_PROTOCOL = 51
        private const val AOA_SEND_STRING = 52
        private const val AOA_START = 53
    }

    private val usb = context.getSystemService(Context.USB_SERVICE) as UsbManager

    @Volatile var state: String = "idle" // idle|waiting|permission|switching|connected|failed|stopped
        private set
    @Volatile var role: String? = null // usb_host|usb_accessory
        private set
    @Volatile var error: String? = null
        private set
    @Volatile var bridge: UsbBridge? = null
        private set
    @Volatile private var stopRequested = false

    /**
     * What the USB stack showed last (diagnostics, device test 2026-11-09 "no permission dialog"):
     * none = this phone sees no USB device and is not an accessory (neither phone became USB host),
     * device = a USB device is attached (we are host), not_android = it did not answer the AOA request,
     * accessory = the peer switched us into accessory mode.
     */
    @Volatile var seen: String = "none"
        private set
    private var worker: Thread? = null

    val hostSupported: Boolean get() = context.packageManager.hasSystemFeature(PackageManager.FEATURE_USB_HOST)
    val accessorySupported: Boolean get() = context.packageManager.hasSystemFeature(PackageManager.FEATURE_USB_ACCESSORY)

    fun status(): Map<String, Any?> = mapOf(
        "supported" to (hostSupported || accessorySupported),
        "hostSupported" to hostSupported,
        "accessorySupported" to accessorySupported,
        "state" to state,
        "role" to role,
        "error" to error,
        "bridgePort" to bridge?.listenPort?.takeIf { it > 0 },
        "seen" to seen,
        "devices" to (try { usb.deviceList.size } catch (_: Exception) { -1 }),
    )

    /**
     * mode "listen": this phone's app is the TLS joiner → expose the link on a 127.0.0.1 port (bridgePort).
     * mode "connect": this phone runs PtpHost on 127.0.0.1:[port] → forward peer connections there.
     * Returns immediately; poll [status] until state is connected or failed.
     */
    @Synchronized
    fun start(mode: String, port: Int, timeoutMs: Long = 90_000) {
        stop()
        stopRequested = false
        seen = "none"
        error = null
        role = null
        state = "waiting"
        val bridgeMode = if (mode == "listen") UsbBridge.Mode.LISTEN else UsbBridge.Mode.CONNECT
        worker = Thread({
            try {
                val link = establish(timeoutMs)
                val b = UsbBridge(link, bridgeMode, port) { ev -> if (ev.startsWith("failed:")) onBridgeFailed(ev.substring(7)) }
                b.start()
                bridge = b
                state = "connected"
            } catch (e: Exception) {
                if (!stopRequested) {
                    error = e.message ?: e.javaClass.simpleName
                    state = "failed"
                }
            }
        }, "usb-establish").apply { isDaemon = true; start() }
    }

    private fun onBridgeFailed(reason: String) {
        if (stopRequested) return
        error = "LINK_LOST:$reason"
        state = "failed"
    }

    @Synchronized
    fun stop() {
        stopRequested = true
        bridge?.close()
        bridge = null
        worker?.interrupt()
        worker = null
        if (state != "idle") state = "stopped"
    }

    // ------------------------------------------------------------------ establishing the link
    private fun establish(timeoutMs: Long): ByteLink {
        if (!hostSupported && !accessorySupported) throw IOException("USB_NOT_SUPPORTED")
        val deadline = System.currentTimeMillis() + timeoutMs
        val triedSwitch = HashSet<String>()
        // Long waits ("auto" mode: a cable may be plugged in at any time) poll less often to save battery.
        val pollMs = if (timeoutMs > 5 * 60_000L) 1_000L else 300L
        while (!stopRequested) {
            if (System.currentTimeMillis() > deadline) throw IOException("USB_TIMEOUT")
            // 1) We are the accessory: the peer already switched us.
            val acc = usb.accessoryList?.firstOrNull()
            if (acc != null) {
                seen = "accessory"
                if (acc.manufacturer != MANUFACTURER || acc.model != MODEL) throw IOException("UNKNOWN_ACCESSORY")
                if (!usb.hasPermission(acc)) {
                    state = "permission"
                    if (!awaitPermission { pi -> usb.requestPermission(acc, pi) }) throw IOException("USB_PERMISSION_DENIED")
                }
                role = "usb_accessory"
                return openAccessory(acc)
            }
            // 2) We are the host and the peer is already in accessory mode.
            val devices = usb.deviceList.values
            if (devices.isNotEmpty() && seen == "none") seen = "device"
            val aoa = devices.firstOrNull { it.vendorId == GOOGLE_VID && it.productId in AOA_PIDS }
            if (aoa != null) {
                if (!usb.hasPermission(aoa)) {
                    state = "permission"
                    if (!awaitPermission { pi -> usb.requestPermission(aoa, pi) }) throw IOException("USB_PERMISSION_DENIED")
                }
                role = "usb_host"
                return openHost(aoa)
            }
            // 3) We are the host and see a phone that is not yet in accessory mode: ask it to switch (AOA).
            for (d in devices) {
                if (!triedSwitch.add(d.deviceName)) continue
                if (!usb.hasPermission(d)) {
                    state = "permission"
                    if (!awaitPermission { pi -> usb.requestPermission(d, pi) }) continue
                }
                state = "switching"
                switchToAccessory(d) // the peer re-enumerates with the Google AOA VID/PID; loop picks it up
            }
            Thread.sleep(pollMs)
        }
        throw IOException("STOPPED")
    }

    /** USB permission dialog; the PendingIntent is explicit (setPackage) and mutable as UsbManager requires. */
    private fun awaitPermission(request: (PendingIntent) -> Unit): Boolean {
        val latch = CountDownLatch(1)
        var granted = false
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: Intent) {
                granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                latch.countDown()
            }
        }
        ContextCompat.registerReceiver(context, receiver, IntentFilter(ACTION_PERMISSION), ContextCompat.RECEIVER_NOT_EXPORTED)
        try {
            val intent = Intent(ACTION_PERMISSION).setPackage(context.packageName)
            val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
            request(PendingIntent.getBroadcast(context, 0, intent, flags))
            latch.await(60, TimeUnit.SECONDS)
        } finally {
            context.unregisterReceiver(receiver)
        }
        return granted
    }

    private fun switchToAccessory(d: UsbDevice) {
        val c = usb.openDevice(d) ?: return
        try {
            val ver = ByteArray(2)
            val n = c.controlTransfer(0xC0, AOA_GET_PROTOCOL, 0, 0, ver, 2, 1000)
            if (n != 2 || (ver[0].toInt() or (ver[1].toInt() shl 8)) < 1) {
                seen = "not_android" // e.g. a USB stick / hub, or a phone that refuses accessory mode
                return
            }
            val strings = listOf(MANUFACTURER, MODEL, DESCRIPTION, VERSION, URI, SERIAL)
            for ((i, s) in strings.withIndex()) {
                val bytes = (s + "\u0000").toByteArray(Charsets.UTF_8)
                c.controlTransfer(0x40, AOA_SEND_STRING, 0, i, bytes, bytes.size, 1000)
            }
            c.controlTransfer(0x40, AOA_START, 0, 0, null, 0, 1000)
        } finally {
            c.close()
        }
    }

    private fun openAccessory(acc: UsbAccessory): ByteLink {
        val pfd = usb.openAccessory(acc) ?: throw IOException("OPEN_ACCESSORY_FAILED")
        return AccessoryLink(pfd)
    }

    private fun openHost(d: UsbDevice): ByteLink {
        val conn = usb.openDevice(d) ?: throw IOException("OPEN_DEVICE_FAILED")
        val intf = (0 until d.interfaceCount).map { d.getInterface(it) }.firstOrNull { i ->
            (0 until i.endpointCount).any { i.getEndpoint(it).type == UsbConstants.USB_ENDPOINT_XFER_BULK }
        } ?: run { conn.close(); throw IOException("NO_BULK_INTERFACE") }
        if (!conn.claimInterface(intf, true)) {
            conn.close()
            throw IOException("CLAIM_FAILED")
        }
        var epIn: UsbEndpoint? = null
        var epOut: UsbEndpoint? = null
        for (i in 0 until intf.endpointCount) {
            val ep = intf.getEndpoint(i)
            if (ep.type != UsbConstants.USB_ENDPOINT_XFER_BULK) continue
            if (ep.direction == UsbConstants.USB_DIR_IN) epIn = ep else epOut = ep
        }
        if (epIn == null || epOut == null) {
            conn.close()
            throw IOException("NO_BULK_ENDPOINTS")
        }
        return HostLink(conn, epIn, epOut)
    }
}

/** Accessory side: the kernel's f_accessory function exposed as a file descriptor. */
private class AccessoryLink(private val pfd: ParcelFileDescriptor) : ByteLink {
    private val fis = FileInputStream(pfd.fileDescriptor)

    // Reads are always a full 16 KiB transfer (BufferedInputStream fills its whole buffer): a read smaller than the
    // incoming USB transfer could drop bytes.
    override val input: InputStream = BufferedInputStream(object : InputStream() {
        override fun read(): Int = throw IOException("unbuffered single-byte read")
        override fun read(b: ByteArray, off: Int, len: Int): Int = fis.read(b, off, minOf(len, Mux.MAX_TRANSFER))
    }, Mux.MAX_TRANSFER)
    override val output: OutputStream = ShortPacketSafeOutputStream(FileOutputStream(pfd.fileDescriptor))
    override fun close() = pfd.close()
}

/** Host side: bulk transfers on the accessory interface. Timeout 0 = block until data or close. */
private class HostLink(
    private val conn: UsbDeviceConnection,
    private val epIn: UsbEndpoint,
    private val epOut: UsbEndpoint,
) : ByteLink {
    // Same rule as the accessory side: every bulk IN request is a full 16 KiB buffer.
    override val input: InputStream = BufferedInputStream(object : InputStream() {
        override fun read(): Int = throw IOException("unbuffered single-byte read")
        override fun read(b: ByteArray, off: Int, len: Int): Int {
            val n = conn.bulkTransfer(epIn, b, off, minOf(len, Mux.MAX_TRANSFER), 0)
            if (n < 0) throw IOException("USB_READ_FAILED")
            return n
        }
    }, Mux.MAX_TRANSFER)
    override val output: OutputStream = ShortPacketSafeOutputStream(object : OutputStream() {
        override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)
        override fun write(b: ByteArray, off: Int, len: Int) {
            var done = 0
            while (done < len) {
                val n = conn.bulkTransfer(epOut, b, off + done, minOf(len - done, Mux.MAX_TRANSFER), 0)
                if (n < 0) throw IOException("USB_WRITE_FAILED")
                done += n
            }
        }
    })

    override fun close() = conn.close()
}
