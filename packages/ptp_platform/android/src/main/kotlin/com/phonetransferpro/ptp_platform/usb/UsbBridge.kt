// USB byte-pipe bridge for Phone Transfer Pro. Pure Kotlin/JVM (no Android APIs) so it is unit-tested on CI.
//
// The USB link (AOA bulk endpoints) carries a tiny multiplexing protocol. Each side exposes the link to the Dart
// app as a TCP socket on 127.0.0.1, so TLS 1.3 + QR pinning + PTP/1 run over USB exactly as over Wi-Fi:
//
//   joiner app ──TCP──▶ [LISTEN bridge] ══USB══ [CONNECT bridge] ──TCP──▶ host app (PtpHost on 127.0.0.1)
//
// Frame: u8 type | u32 BE connId | u32 BE length | payload (≤ MAX_PAYLOAD). Types: HELLO, OPEN, DATA, CLOSE.
// The bridge never interprets payload bytes: authentication and encryption stay end-to-end in the app (the cable
// is not trusted).
package com.phonetransferpro.ptp_platform.usb

import java.io.Closeable
import java.io.DataInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** A bidirectional byte stream: USB AOA in production, pipes in tests. */
interface ByteLink : Closeable {
    val input: InputStream
    val output: OutputStream
}

object Mux {
    const val HELLO: Int = 0
    const val OPEN: Int = 1
    const val DATA: Int = 2
    const val CLOSE: Int = 3
    const val HEADER: Int = 9

    /** One USB write = header + payload ≤ 16 KiB, the transfer size every Android USB stack accepts. */
    const val MAX_TRANSFER: Int = 16 * 1024
    const val MAX_PAYLOAD: Int = MAX_TRANSFER - HEADER
    val MAGIC: ByteArray = "PTPUSB1".toByteArray(Charsets.US_ASCII)
}

/**
 * USB bulk transfers end on a short packet. A write whose length is a multiple of the max packet size (64/512/1024)
 * would leave the reader waiting for more data, because Android's APIs do not let an app send a zero-length packet.
 * Splitting off the last byte makes every logical write end with a short packet. 64 divides all USB packet sizes.
 */
class ShortPacketSafeOutputStream(private val out: OutputStream, private val packet: Int = 64) : OutputStream() {
    override fun write(b: Int) = out.write(b)

    override fun write(b: ByteArray, off: Int, len: Int) {
        if (len > 1 && len % packet == 0) {
            out.write(b, off, len - 1)
            out.write(b, off + len - 1, 1)
        } else if (len > 0) {
            out.write(b, off, len)
        }
    }

    override fun flush() = out.flush()
    override fun close() = out.close()
}

class UsbBridgeException(message: String) : IOException(message)

/**
 * mode LISTEN: accept app connections on 127.0.0.1 and forward them over USB (joiner side).
 * mode CONNECT: on OPEN from the peer, connect to 127.0.0.1:[targetPort] (the PtpHost side).
 * In LISTEN mode a non-zero [targetPort] is the port to listen on, so a relinked cable keeps the address the app
 * already uses for its resume reconnect.
 */
class UsbBridge(
    private val link: ByteLink,
    private val mode: Mode,
    private val targetPort: Int = 0,
    private val onEvent: (String) -> Unit = {},
) : Closeable {
    enum class Mode { LISTEN, CONNECT }

    private val writeLock = Any()
    private val conns = ConcurrentHashMap<Int, Socket>()
    private val nextId = AtomicInteger(1)
    private val closed = AtomicBoolean(false)
    private val helloSeen = CountDownLatch(1)
    private var server: ServerSocket? = null
    private val threads = mutableListOf<Thread>()

    /** Port the joiner app must connect to (LISTEN mode only). */
    val listenPort: Int get() = server?.localPort ?: 0

    @Volatile var failure: String? = null
        private set

    /** Starts the bridge and waits for the peer's HELLO (peer app present and speaking the same version). */
    fun start(helloTimeoutMs: Long = 30_000) {
        if (mode == Mode.LISTEN) {
            server = ServerSocket().apply {
                reuseAddress = true
                bind(InetSocketAddress(InetAddress.getLoopbackAddress(), targetPort), 4)
            }
        }
        spawn("usb-reader") { readLoop() }
        sendFrame(Mux.HELLO, 0, Mux.MAGIC, 0, Mux.MAGIC.size)
        if (!helloSeen.await(helloTimeoutMs, TimeUnit.MILLISECONDS)) {
            close()
            throw UsbBridgeException("PEER_TIMEOUT")
        }
        failure?.let { throw UsbBridgeException(it) }
        if (mode == Mode.LISTEN) spawn("usb-accept") { acceptLoop() }
        onEvent("connected")
    }

    private fun spawn(name: String, body: () -> Unit) {
        val t = Thread({
            try {
                body()
            } catch (e: Exception) {
                fail(e.javaClass.simpleName)
            }
        }, name)
        t.isDaemon = true
        synchronized(threads) { threads.add(t) }
        t.start()
    }

    private fun sendFrame(type: Int, id: Int, data: ByteArray, off: Int, len: Int) {
        require(len in 0..Mux.MAX_PAYLOAD)
        val frame = ByteBuffer.allocate(Mux.HEADER + len)
        frame.put(type.toByte()).putInt(id).putInt(len).put(data, off, len)
        synchronized(writeLock) {
            if (closed.get()) throw UsbBridgeException("CLOSED")
            link.output.write(frame.array(), 0, frame.position())
            link.output.flush()
        }
    }

    private fun readLoop() {
        val din = DataInputStream(link.input)
        val buf = ByteArray(Mux.MAX_PAYLOAD)
        while (!closed.get()) {
            val type = din.readUnsignedByte()
            val id = din.readInt()
            val len = din.readInt()
            if (len < 0 || len > Mux.MAX_PAYLOAD) throw UsbBridgeException("PROTOCOL_ERROR")
            din.readFully(buf, 0, len)
            when (type) {
                Mux.HELLO -> {
                    if (!buf.copyOf(len).contentEquals(Mux.MAGIC)) {
                        failure = "PROTOCOL_VERSION_MISMATCH"
                        helloSeen.countDown()
                        throw UsbBridgeException("PROTOCOL_VERSION_MISMATCH")
                    }
                    helloSeen.countDown()
                }
                Mux.OPEN -> {
                    if (mode != Mode.CONNECT) throw UsbBridgeException("PROTOCOL_ERROR")
                    val s = Socket(InetAddress.getLoopbackAddress(), targetPort)
                    s.tcpNoDelay = true
                    conns[id] = s
                    spawn("usb-pump-$id") { pumpSocketToUsb(id, s) }
                }
                Mux.DATA -> {
                    // Blocking write = backpressure: a slow app stops the USB reader, which stops the peer's writer.
                    try {
                        conns[id]?.getOutputStream()?.write(buf, 0, len)
                    } catch (e: IOException) {
                        closeConn(id, notifyPeer = true)
                    }
                }
                Mux.CLOSE -> closeConn(id, notifyPeer = false)
                else -> throw UsbBridgeException("PROTOCOL_ERROR")
            }
        }
    }

    private fun acceptLoop() {
        val srv = server ?: return
        while (!closed.get()) {
            val s = try {
                srv.accept()
            } catch (e: IOException) {
                if (closed.get()) return else throw e
            }
            s.tcpNoDelay = true
            val id = nextId.getAndIncrement()
            conns[id] = s
            sendFrame(Mux.OPEN, id, ByteArray(0), 0, 0)
            spawn("usb-pump-$id") { pumpSocketToUsb(id, s) }
        }
    }

    private fun pumpSocketToUsb(id: Int, s: Socket) {
        val inp = s.getInputStream()
        val buf = ByteArray(Mux.MAX_PAYLOAD)
        try {
            while (!closed.get()) {
                val n = inp.read(buf)
                if (n < 0) break
                if (n > 0) sendFrame(Mux.DATA, id, buf, 0, n)
            }
        } catch (e: IOException) {
            // socket closed locally or reset; fall through to CLOSE
        }
        closeConn(id, notifyPeer = true)
    }

    private fun closeConn(id: Int, notifyPeer: Boolean) {
        val s = conns.remove(id) ?: return
        try {
            s.close()
        } catch (_: IOException) {
        }
        if (notifyPeer && !closed.get()) {
            try {
                sendFrame(Mux.CLOSE, id, ByteArray(0), 0, 0)
            } catch (_: IOException) {
            }
        }
    }

    private fun fail(reason: String) {
        if (closed.get()) return
        failure = failure ?: reason
        helloSeen.countDown()
        onEvent("failed:$reason")
        close()
    }

    /** Closes every app socket (the app sees NETWORK_INTERRUPTED and runs its resume logic) and the USB link. */
    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        try {
            server?.close()
        } catch (_: IOException) {
        }
        for (id in conns.keys.toList()) {
            try {
                conns.remove(id)?.close()
            } catch (_: IOException) {
            }
        }
        try {
            link.close()
        } catch (_: IOException) {
        }
        onEvent("closed")
    }

    val isOpen: Boolean get() = !closed.get()
}
