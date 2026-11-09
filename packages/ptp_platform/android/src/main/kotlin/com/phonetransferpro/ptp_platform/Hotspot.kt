// Phone Transfer Pro — phone-to-phone Wi-Fi without a router ("Điểm phát", like OPPO Clone Phone / Smart Switch).
// NOT TESTED ON DEVICES (see docs/STATUS.md).
//
// Host: WifiManager.startLocalOnlyHotspot — an app-scoped hotspot with a system-generated name and password and no
// Internet sharing. The name/password go into the pairing QR only (never logged).
// Joiner: WifiNetworkSpecifier request (the system shows its own "connect to this device?" dialog), then the process is
// bound to that network so the transfer socket uses the direct link and not the router / mobile data.
package com.phonetransferpro.ptp_platform

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.SoftApConfiguration
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.net.Inet4Address
import java.net.NetworkInterface

class Hotspot(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private val wifi get() = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val cm get() = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private var reservation: WifiManager.LocalOnlyHotspotReservation? = null
    private var joinCallback: ConnectivityManager.NetworkCallback? = null
    private var joined: Network? = null

    // ------------------------------------------------------------------ host
    /** Starts the hotspot. Calls [done] exactly once with (info, null) or (null, errorCode). Main thread. */
    fun start(done: (Map<String, Any?>?, String?) -> Unit) {
        stop()
        var answered = false
        fun answer(v: Map<String, Any?>?, err: String?) {
            if (!answered) {
                answered = true
                done(v, err)
            }
        }
        try {
            wifi.startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
                override fun onStarted(r: WifiManager.LocalOnlyHotspotReservation) {
                    reservation = r
                    val info = describe(r)
                    if (info == null) {
                        stop()
                        answer(null, "HOTSPOT_NO_CONFIG")
                        return
                    }
                    // The AP interface may take a moment to get its address; the QR lists it first when found.
                    waitForApAddress(20) { ips -> answer(info + mapOf("ips" to ips), null) }
                }

                override fun onStopped() {
                    reservation = null
                }

                override fun onFailed(reason: Int) {
                    answer(null, when (reason) {
                        WifiManager.LocalOnlyHotspotCallback.ERROR_INCOMPATIBLE_MODE -> "HOTSPOT_INCOMPATIBLE_MODE" // the normal hotspot is already on
                        WifiManager.LocalOnlyHotspotCallback.ERROR_TETHERING_DISALLOWED -> "HOTSPOT_DISALLOWED"
                        WifiManager.LocalOnlyHotspotCallback.ERROR_NO_CHANNEL -> "HOTSPOT_NO_CHANNEL"
                        else -> "HOTSPOT_FAILED"
                    })
                }
            }, main)
        } catch (e: SecurityException) {
            answer(null, "HOTSPOT_PERMISSION")
        } catch (e: IllegalStateException) {
            answer(null, "HOTSPOT_BUSY")
        }
    }

    fun stop() {
        try {
            reservation?.close()
        } catch (_: Exception) {
        }
        reservation = null
    }

    val hosting get() = reservation != null

    private fun describe(r: WifiManager.LocalOnlyHotspotReservation): Map<String, Any?>? {
        if (Build.VERSION.SDK_INT >= 30) {
            val c = r.softApConfiguration
            val ssid = if (Build.VERSION.SDK_INT >= 33) {
                c.wifiSsid?.toString()?.removeSurrounding("\"")
            } else {
                @Suppress("DEPRECATION") c.ssid
            }
            val psk = c.passphrase
            if (ssid.isNullOrEmpty() || psk.isNullOrEmpty()) return null
            val sec = when (c.securityType) {
                SoftApConfiguration.SECURITY_TYPE_WPA3_SAE -> "wpa3"
                else -> "wpa2" // WPA2 and WPA3 transition mode both accept a WPA2 client
            }
            return mapOf("ssid" to ssid, "psk" to psk, "sec" to sec) // band is not public API; the OS picks it
        }
        @Suppress("DEPRECATION")
        val c = r.wifiConfiguration ?: return null
        @Suppress("DEPRECATION")
        val ssid = c.SSID?.removeSurrounding("\"")
        @Suppress("DEPRECATION")
        val psk = c.preSharedKey?.removeSurrounding("\"")
        if (ssid.isNullOrEmpty() || psk.isNullOrEmpty()) return null
        return mapOf("ssid" to ssid, "psk" to psk, "sec" to "wpa2")
    }

    private fun waitForApAddress(triesLeft: Int, done: (List<String>) -> Unit) {
        val ips = apAddresses()
        if (ips.isNotEmpty() || triesLeft <= 0) done(ips) else main.postDelayed({ waitForApAddress(triesLeft - 1, done) }, 150)
    }

    /** IPv4 addresses of soft-AP interfaces (names vary by vendor: ap0, swlan0, wlan1, softap0 …). */
    private fun apAddresses(): List<String> = try {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && AP_NAME.matches(it.name) }
            .flatMap { i -> i.inetAddresses.toList().filterIsInstance<Inet4Address>().filter { !it.isLoopbackAddress } }
            .map { it.hostAddress ?: "" }
            .filter { it.isNotEmpty() }
    } catch (_: Exception) {
        emptyList()
    }

    // ------------------------------------------------------------------ joiner
    /**
     * Asks the system to connect to the host's hotspot (it shows its own confirmation dialog), then binds this process
     * to that network. Calls [done] once with (gatewayIp or "", null) or (null, errorCode). Main thread.
     */
    fun join(ssid: String, psk: String, sec: String, timeoutMs: Int, done: (String?, String?) -> Unit) {
        leave()
        var answered = false
        fun answer(v: String?, err: String?) {
            if (!answered) {
                answered = true
                done(v, err)
            }
        }
        val spec = WifiNetworkSpecifier.Builder().setSsid(ssid).apply {
            if (sec == "wpa3") setWpa3Passphrase(psk) else setWpa2Passphrase(psk)
        }.build()
        val req = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(spec)
            .build()
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                joined = network
                cm.bindProcessToNetwork(network)
                main.post { answer(gateway(network), null) }
            }

            override fun onUnavailable() {
                main.post { answer(null, "HOTSPOT_JOIN_FAILED") } // not found, wrong password or the user declined
            }

            override fun onLost(network: Network) {
                // Keep the binding: the transfer's resume logic redials and the system may bring the link back.
                // Unbinding here would send the redial to the router, where the host is not reachable.
            }
        }
        joinCallback = cb
        try {
            cm.requestNetwork(req, cb, timeoutMs)
        } catch (e: SecurityException) {
            joinCallback = null
            answer(null, "HOTSPOT_PERMISSION")
        } catch (e: Exception) {
            joinCallback = null
            answer(null, "HOTSPOT_JOIN_FAILED")
        }
    }

    fun leave() {
        joinCallback?.let {
            try {
                cm.unregisterNetworkCallback(it)
            } catch (_: Exception) {
            }
        }
        joinCallback = null
        if (joined != null) {
            try {
                cm.bindProcessToNetwork(null)
            } catch (_: Exception) {
            }
        }
        joined = null
    }

    private fun gateway(network: Network): String {
        val lp = cm.getLinkProperties(network) ?: return ""
        lp.routes.firstOrNull { it.isDefaultRoute && it.gateway is Inet4Address }?.gateway?.hostAddress?.let {
            if (it != "0.0.0.0") return it
        }
        if (Build.VERSION.SDK_INT >= 30) {
            (lp.dhcpServerAddress as? Inet4Address)?.hostAddress?.let { return it }
        }
        return ""
    }

    /** Current link rate of the router Wi-Fi in Mbps (for the "slow Wi-Fi" hint); -1 when unknown. */
    @Suppress("DEPRECATION")
    fun linkMbps(): Int = try {
        val info = wifi.connectionInfo
        if (info == null || info.networkId == -1) -1 else info.linkSpeed
    } catch (_: Exception) {
        -1
    }

    companion object {
        private val AP_NAME = Regex("^(ap|swlan|softap|wlan[1-9]|wifi_ap|wigig)\\d*$")
    }
}
