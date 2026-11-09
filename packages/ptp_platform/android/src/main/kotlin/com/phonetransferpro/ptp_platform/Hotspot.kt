// Phone Transfer Pro — phone-to-phone Wi-Fi without a router ("Điểm phát", like OPPO Clone Phone / Smart Switch).
// NOT TESTED ON DEVICES (see docs/STATUS.md).
//
// Host, first choice: a Wi-Fi Direct group (WifiP2pManager.createGroup) with a random name/password, on 5 GHz when this
// phone supports it (setGroupOperatingBand), else on any band. Router Wi-Fi is not needed, only Wi-Fi switched on.
// Host, fallback: WifiManager.startLocalOnlyHotspot (system-chosen name/password/band).
// The name/password go into the pairing QR only (never logged). No Internet is shared.
// Joiner (Android): Wi-Fi Direct group -> WifiP2pManager.connect with the name/password (no pairing dialog);
// local-only hotspot -> WifiNetworkSpecifier (system dialog) + bindProcessToNetwork.
// Joiner (iPhone, Swift side): joins either one as an ordinary WPA2 network.
package com.phonetransferpro.ptp_platform

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.SoftApConfiguration
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pGroup
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.content.pm.PackageManager
import java.security.SecureRandom
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

    private val p2p: WifiP2pManager? get() =
        if (context.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT))
            context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager else null
    private var channel: WifiP2pManager.Channel? = null
    private var p2pHosting = false
    private var p2pJoined = false
    private var pollGen = 0

    private fun ch(m: WifiP2pManager): WifiP2pManager.Channel =
        channel ?: m.initialize(context, Looper.getMainLooper(), null).also { channel = it }

    /** 5 GHz support of THIS phone (Wi-Fi Direct hosting and joining use it when true). */
    val supports5Ghz: Boolean get() = try { wifi.is5GHzBandSupported } catch (_: Exception) { false }

    // ------------------------------------------------------------------ host (public entry)
    /**
     * Creates the direct link. Order: Wi-Fi Direct on 5 GHz (if supported and not [force24]) -> Wi-Fi Direct on
     * 2.4 GHz/any band -> local-only hotspot. Answers once with
     * {ssid, psk, sec, mode: p2p|ap, band: 5|2|a, ips} or an error code. Main thread.
     */
    fun start(force24: Boolean, done: (Map<String, Any?>?, String?) -> Unit) {
        stop()
        if (!wifi.isWifiEnabled) return done(null, "HOTSPOT_WIFI_OFF")
        val m = p2p
        if (m == null) return startLohs(done)
        val first = if (!force24 && supports5Ghz) WifiP2pConfig.GROUP_OWNER_BAND_5GHZ
            else if (force24) WifiP2pConfig.GROUP_OWNER_BAND_2GHZ else WifiP2pConfig.GROUP_OWNER_BAND_AUTO
        startGroup(m, first) { info, err ->
            if (info != null) return@startGroup done(info, null)
            if (err == "HOTSPOT_PERMISSION") return@startGroup done(null, err)
            if (first == WifiP2pConfig.GROUP_OWNER_BAND_5GHZ) {
                // The phone could not open a 5 GHz group right now (e.g. radio busy): let the system pick.
                startGroup(m, WifiP2pConfig.GROUP_OWNER_BAND_AUTO) { info2, err2 ->
                    if (info2 != null) done(info2, null) else if (err2 == "HOTSPOT_PERMISSION") done(null, err2) else startLohs(done)
                }
            } else {
                startLohs(done)
            }
        }
    }

    private fun startGroup(m: WifiP2pManager, band: Int, done: (Map<String, Any?>?, String?) -> Unit) {
        val c = ch(m)
        val name = "DIRECT-${random(2)}-ChuyenDL"
        val pass = random(16)
        val cfg = try {
            WifiP2pConfig.Builder().setNetworkName(name).setPassphrase(pass).setGroupOperatingBand(band).build()
        } catch (e: Exception) {
            return done(null, "HOTSPOT_FAILED")
        }
        val create = {
            try {
                m.createGroup(c, cfg, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        p2pHosting = true
                        waitForGroup(m, c, 40, name, pass, done)
                    }

                    override fun onFailure(reason: Int) {
                        done(null, if (reason == WifiP2pManager.BUSY) "HOTSPOT_BUSY" else "HOTSPOT_FAILED")
                    }
                })
            } catch (e: SecurityException) {
                done(null, "HOTSPOT_PERMISSION")
            }
        }
        // A group left over from an earlier session would make createGroup fail with BUSY.
        try {
            m.removeGroup(c, object : WifiP2pManager.ActionListener {
                override fun onSuccess() = create()
                override fun onFailure(reason: Int) = create()
            })
        } catch (e: SecurityException) {
            done(null, "HOTSPOT_PERMISSION")
        }
    }

    private fun waitForGroup(m: WifiP2pManager, c: WifiP2pManager.Channel, triesLeft: Int, name: String, pass: String,
                             done: (Map<String, Any?>?, String?) -> Unit) {
        try {
            m.requestGroupInfo(c) { g: WifiP2pGroup? ->
                if (g != null && g.isGroupOwner && g.networkName == name) {
                    m.requestConnectionInfo(c) { info: WifiP2pInfo? ->
                        val ips = mutableListOf<String>()
                        info?.groupOwnerAddress?.hostAddress?.let { ips.add(it) }
                        ifaceAddresses(g.`interface`).forEach { if (it !in ips) ips.add(it) }
                        val freq = if (Build.VERSION.SDK_INT >= 29) g.frequency else 0
                        val bandTag = when {
                            freq >= 4900 -> "5"
                            freq in 2400..2500 -> "2"
                            else -> "a"
                        }
                        done(mapOf("ssid" to name, "psk" to pass, "sec" to "wpa2", "mode" to "p2p", "band" to bandTag,
                            "ips" to ips), null)
                    }
                } else if (triesLeft <= 0) {
                    stop()
                    done(null, "HOTSPOT_FAILED")
                } else {
                    main.postDelayed({ waitForGroup(m, c, triesLeft - 1, name, pass, done) }, 150)
                }
            }
        } catch (e: SecurityException) {
            done(null, "HOTSPOT_PERMISSION")
        }
    }

    private fun ifaceAddresses(name: String?): List<String> = try {
        if (name == null) emptyList() else NetworkInterface.getByName(name)?.inetAddresses?.toList()
            ?.filterIsInstance<Inet4Address>()?.mapNotNull { it.hostAddress } ?: emptyList()
    } catch (_: Exception) {
        emptyList()
    }

    // ------------------------------------------------------------------ joiner (public entry)
    /** [mode] p2p | ap; [band] 5 | 2 | a. Answers once with (host IPv4 or "", null) or (null, errorCode). Main thread. */
    fun join(ssid: String, psk: String, sec: String, mode: String, band: String, timeoutMs: Int,
             done: (String?, String?) -> Unit) {
        leave()
        if (!wifi.isWifiEnabled) return done(null, "HOTSPOT_WIFI_OFF")
        if (band == "5" && !supports5Ghz) return done(null, "HOTSPOT_NO_5GHZ")
        val m = p2p
        if (mode == "p2p" && m != null) joinGroup(m, ssid, psk, band, timeoutMs, done)
        else joinAp(ssid, psk, sec, timeoutMs, done)
    }

    private fun joinGroup(m: WifiP2pManager, ssid: String, psk: String, band: String, timeoutMs: Int,
                          done: (String?, String?) -> Unit) {
        val c = ch(m)
        val cfg = try {
            WifiP2pConfig.Builder().setNetworkName(ssid).setPassphrase(psk).setGroupOperatingBand(
                when (band) {
                    "5" -> WifiP2pConfig.GROUP_OWNER_BAND_5GHZ
                    "2" -> WifiP2pConfig.GROUP_OWNER_BAND_2GHZ
                    else -> WifiP2pConfig.GROUP_OWNER_BAND_AUTO
                }).build()
        } catch (e: Exception) {
            return done(null, "HOTSPOT_JOIN_FAILED")
        }
        var answered = false
        fun answer(v: String?, err: String?) {
            if (!answered) {
                answered = true
                done(v, err)
            }
        }
        val gen = ++pollGen
        val deadline = System.currentTimeMillis() + timeoutMs
        fun poll() {
            if (gen != pollGen || answered) return
            try {
                m.requestConnectionInfo(c) { info: WifiP2pInfo? ->
                    val owner = info?.groupOwnerAddress?.hostAddress
                    if (info != null && info.groupFormed && !info.isGroupOwner && owner != null) {
                        p2pJoined = true
                        answer(owner, null)
                    } else if (System.currentTimeMillis() > deadline) {
                        try { m.cancelConnect(c, null) } catch (_: Exception) {}
                        answer(null, "HOTSPOT_JOIN_FAILED")
                    } else {
                        main.postDelayed({ poll() }, 400)
                    }
                }
            } catch (e: SecurityException) {
                answer(null, "HOTSPOT_PERMISSION")
            }
        }
        val connect = {
            try {
                // Name + password are known, so the system joins without a pairing dialog on either phone.
                m.connect(c, cfg, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() = poll()
                    override fun onFailure(reason: Int) = answer(null, "HOTSPOT_JOIN_FAILED")
                })
            } catch (e: SecurityException) {
                answer(null, "HOTSPOT_PERMISSION")
            }
        }
        try {
            m.removeGroup(c, object : WifiP2pManager.ActionListener {
                override fun onSuccess() = connect()
                override fun onFailure(reason: Int) = connect()
            })
        } catch (e: SecurityException) {
            answer(null, "HOTSPOT_PERMISSION")
        }
    }

    private fun random(n: Int): String {
        val abc = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789"
        val r = SecureRandom()
        return String(CharArray(n) { abc[r.nextInt(abc.length)] })
    }

    // ------------------------------------------------------------------ host
    /** Fallback host: local-only hotspot. Calls [done] exactly once with (info, null) or (null, errorCode). */
    private fun startLohs(done: (Map<String, Any?>?, String?) -> Unit) {
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
        val m = p2p
        val c = channel
        if (p2pHosting && m != null && c != null) {
            try {
                m.removeGroup(c, null)
            } catch (_: Exception) {
            }
        }
        p2pHosting = false
    }

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
            return mapOf("ssid" to ssid, "psk" to psk, "sec" to sec, "mode" to "ap", "band" to "a") // the OS picks the band
        }
        @Suppress("DEPRECATION")
        val c = r.wifiConfiguration ?: return null
        @Suppress("DEPRECATION")
        val ssid = c.SSID?.removeSurrounding("\"")
        @Suppress("DEPRECATION")
        val psk = c.preSharedKey?.removeSurrounding("\"")
        if (ssid.isNullOrEmpty() || psk.isNullOrEmpty()) return null
        return mapOf("ssid" to ssid, "psk" to psk, "sec" to "wpa2", "mode" to "ap", "band" to "a")
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
    private fun joinAp(ssid: String, psk: String, sec: String, timeoutMs: Int, done: (String?, String?) -> Unit) {
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
        pollGen++
        val m = p2p
        val c = channel
        if (p2pJoined && m != null && c != null) {
            try {
                m.removeGroup(c, null)
            } catch (_: Exception) {
            }
        }
        p2pJoined = false
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
