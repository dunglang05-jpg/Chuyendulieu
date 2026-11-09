// JVM unit tests for the USB mux bridge. The "cable" is simulated by a TCP socket pair; both bridges, the app-side
// sockets and the backpressure path are real. These tests do NOT prove AOA works on any phone (see TEST_REPORT).
package com.phonetransferpro.ptp_platform.usb

import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.Random
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class SocketLink(private val s: Socket) : ByteLink {
    override val input: InputStream = s.getInputStream()
    override val output: OutputStream = ShortPacketSafeOutputStream(s.getOutputStream())
    override fun close() = s.close()
}

class UsbBridgeTest {
    private val pool = Executors.newCachedThreadPool()
    private val closeables = mutableListOf<AutoCloseable>()

    @After
    fun tearDown() {
        closeables.reversed().forEach { runCatching { it.close() } }
        pool.shutdownNow()
    }

    private fun cable(): Pair<Socket, Socket> {
        val srv = ServerSocket(0, 1, InetAddress.getLoopbackAddress())
        val f = pool.submit<Socket> { srv.accept() }
        val a = Socket(InetAddress.getLoopbackAddress(), srv.localPort)
        val b = f.get(5, TimeUnit.SECONDS)
        srv.close()
        closeables += a
        closeables += b
        return a to b
    }

    /** Stands in for PtpHost: for each connection, read N bytes, answer with their SHA-256 and N bytes of its own. */
    private fun appServer(): ServerSocket {
        val srv = ServerSocket(0, 4, InetAddress.getLoopbackAddress())
        closeables += srv
        pool.submit {
            while (!srv.isClosed) {
                val s = try { srv.accept() } catch (e: IOException) { break }
                pool.submit {
                    s.use {
                        val din = DataInputStream(it.getInputStream())
                        val n = din.readInt()
                        val data = ByteArray(n)
                        din.readFully(data)
                        val out = DataOutputStream(it.getOutputStream())
                        out.write(sha(data))
                        out.write(data.reversedArray())
                        out.flush()
                    }
                }
            }
        }
        return srv
    }

    private fun sha(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b)

    private fun pair(): Pair<UsbBridge, UsbBridge> {
        val (a, b) = cable()
        val app = appServer()
        val listen = UsbBridge(SocketLink(a), UsbBridge.Mode.LISTEN)
        val connect = UsbBridge(SocketLink(b), UsbBridge.Mode.CONNECT, app.localPort)
        closeables += listen
        closeables += connect
        val f = pool.submit { connect.start(5_000) }
        listen.start(5_000)
        f.get(5, TimeUnit.SECONDS)
        return listen to connect
    }

    private fun roundTrip(port: Int, size: Int, seed: Long) {
        val data = ByteArray(size).also { Random(seed).nextBytes(it) }
        Socket(InetAddress.getLoopbackAddress(), port).use { s ->
            s.soTimeout = 15_000
            val out = DataOutputStream(s.getOutputStream())
            out.writeInt(size)
            out.write(data)
            out.flush()
            val din = DataInputStream(s.getInputStream())
            val digest = ByteArray(32).also { din.readFully(it) }
            val back = ByteArray(size).also { din.readFully(it) }
            assertArrayEquals("SHA-256 of what the far app received", sha(data), digest)
            assertArrayEquals("bytes coming back", data.reversedArray(), back)
        }
    }

    @Test
    fun carriesLargeDataBothWaysIntact() {
        val (listen, _) = pair()
        assertTrue(listen.listenPort > 0)
        roundTrip(listen.listenPort, 5 * 1024 * 1024 + 123, 1)
    }

    @Test
    fun secondConnectionWorksAfterFirstClosesLikeAResume() {
        val (listen, _) = pair()
        roundTrip(listen.listenPort, 300_000, 2)
        roundTrip(listen.listenPort, 1_000_000, 3)
        roundTrip(listen.listenPort, 1, 4)
    }

    @Test
    fun cableLossClosesAppSockets() {
        val (a, b) = cable()
        val app = appServer()
        val listen = UsbBridge(SocketLink(a), UsbBridge.Mode.LISTEN)
        val connect = UsbBridge(SocketLink(b), UsbBridge.Mode.CONNECT, app.localPort)
        closeables += listen; closeables += connect
        val f = pool.submit { connect.start(5_000) }
        listen.start(5_000)
        f.get(5, TimeUnit.SECONDS)
        val s = Socket(InetAddress.getLoopbackAddress(), listen.listenPort)
        closeables += s
        s.soTimeout = 5_000
        Thread.sleep(200)
        b.close() // unplug
        val r = try { s.getInputStream().read() } catch (e: IOException) { -1 }
        assertEquals("app sees end of stream so its resume logic can start", -1, r)
        Thread.sleep(200)
        assertTrue(!listen.isOpen)
    }

    @Test
    fun wrongPeerVersionIsRejected() {
        val (a, b) = cable()
        val listen = UsbBridge(SocketLink(a), UsbBridge.Mode.LISTEN)
        closeables += listen
        pool.submit {
            val magic = "BADPEER".toByteArray()
            val frame = ByteBuffer.allocate(Mux.HEADER + magic.size).put(Mux.HELLO.toByte()).putInt(0).putInt(magic.size).put(magic)
            b.getOutputStream().write(frame.array())
        }
        try {
            listen.start(5_000)
            fail("must not connect to a peer speaking another protocol")
        } catch (e: UsbBridgeException) {
            assertEquals("PROTOCOL_VERSION_MISMATCH", e.message)
        }
    }

    @Test
    fun oversizedFrameKillsTheLink() {
        val (a, b) = cable()
        val app = appServer()
        val connect = UsbBridge(SocketLink(a), UsbBridge.Mode.CONNECT, app.localPort)
        closeables += connect
        pool.submit {
            val out = b.getOutputStream()
            val hello = ByteBuffer.allocate(Mux.HEADER + Mux.MAGIC.size).put(Mux.HELLO.toByte()).putInt(0).putInt(Mux.MAGIC.size).put(Mux.MAGIC)
            out.write(hello.array())
            Thread.sleep(300)
            out.write(ByteBuffer.allocate(Mux.HEADER).put(Mux.DATA.toByte()).putInt(1).putInt(Mux.MAX_PAYLOAD + 1).array())
        }
        connect.start(5_000)
        val deadline = System.currentTimeMillis() + 5_000
        while (connect.isOpen && System.currentTimeMillis() < deadline) Thread.sleep(50)
        assertTrue("bridge must close on a malformed frame", !connect.isOpen)
        assertEquals("PROTOCOL_ERROR", connect.failure)
    }

    @Test
    fun writesThatAreAMultipleOfThePacketSizeEndWithAShortPacket() {
        val writes = mutableListOf<Int>()
        val sink = object : OutputStream() {
            override fun write(b: Int) { writes += 1 }
            override fun write(b: ByteArray, off: Int, len: Int) { writes += len }
        }
        val s = ShortPacketSafeOutputStream(sink)
        s.write(ByteArray(512), 0, 512)
        s.write(ByteArray(100), 0, 100)
        s.write(ByteArray(16384), 0, 16384)
        s.write(ByteArray(64), 0, 64)
        assertEquals(listOf(511, 1, 100, 16383, 1, 63, 1), writes)
        val all = ByteArrayOutputStream()
        val s2 = ShortPacketSafeOutputStream(all)
        val data = ByteArray(1024).also { Random(9).nextBytes(it) }
        s2.write(data, 0, data.size)
        assertArrayEquals("splitting must not change the bytes", data, all.toByteArray())
    }
}

class UsbBridgeRelinkTest {
    @Test
    fun relinkedListenBridgeKeepsThePortTheAppAlreadyUses() {
        val pool = Executors.newCachedThreadPool()
        try {
            fun cable(): Pair<Socket, Socket> {
                val srv = ServerSocket(0, 1, InetAddress.getLoopbackAddress())
                val f = pool.submit<Socket> { srv.accept() }
                val a = Socket(InetAddress.getLoopbackAddress(), srv.localPort)
                return (a to f.get(5, TimeUnit.SECONDS)).also { srv.close() }
            }
            val app = ServerSocket(0, 4, InetAddress.getLoopbackAddress())
            val (a1, b1) = cable()
            val l1 = UsbBridge(SocketLink(a1), UsbBridge.Mode.LISTEN)
            val c1 = UsbBridge(SocketLink(b1), UsbBridge.Mode.CONNECT, app.localPort)
            val f1 = pool.submit { c1.start(5_000) }
            l1.start(5_000); f1.get(5, TimeUnit.SECONDS)
            val port = l1.listenPort
            b1.close() // cable unplugged
            Thread.sleep(300)
            val (a2, b2) = cable() // cable plugged back
            val l2 = UsbBridge(SocketLink(a2), UsbBridge.Mode.LISTEN, port)
            val c2 = UsbBridge(SocketLink(b2), UsbBridge.Mode.CONNECT, app.localPort)
            val f2 = pool.submit { c2.start(5_000) }
            l2.start(5_000); f2.get(5, TimeUnit.SECONDS)
            assertEquals(port, l2.listenPort)
            l2.close(); c2.close(); l1.close(); c1.close(); app.close()
        } finally {
            pool.shutdownNow()
        }
    }
}
