"""PTP/1 pairing (host/joiner), capability exchange and the sender/receiver transfer engines."""
from __future__ import annotations

import asyncio
import hashlib
import hmac
import os
import platform as _platform
import shutil
import ssl
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Awaitable, Callable, Optional

from . import core as c
from .core import PtpError
from .store import ReceiverStore

ConfirmCb = Callable[[str, dict], Awaitable[bool]]


async def auto_confirm(sas: str, peer: dict) -> bool:  # tests / headless use only
    return True


def reference_caps(role: str, free_bytes: Optional[int] = None) -> dict:
    return {
        "protocolVersion": str(c.PROTOCOL_VERSION),
        "platform": "desktop_reference",
        "role": role,
        "osVersion": f"{_platform.system()} {_platform.release()}",
        "appVersion": "ref-0.1.0",
        "categories": [{"id": k, "export": True, "import": True, "status": "supported"} for k in c.CATEGORIES],
        "transports": ["lan_tcp_tls13"],
        "permissions": {k: "not_applicable" for k in c.CATEGORIES},
        "freeStorageBytes": free_bytes,
        "maxFileSizeBytes": c.MAX_FILE_SIZE,
        "backgroundTransfer": True,
        "backgroundConstraints": "none",
        "cryptoSuites": ["TLS_AES_128_GCM_SHA256", "TLS_AES_256_GCM_SHA384", "TLS_CHACHA20_POLY1305_SHA256"],
    }


def validate_caps(caps) -> dict:
    if not isinstance(caps, dict):
        raise PtpError("PROTOCOL_ERROR", "caps not an object")
    if caps.get("protocolVersion") != str(c.PROTOCOL_VERSION) or caps.get("platform") not in c.PLATFORMS:
        raise PtpError("PROTOCOL_VERSION_MISMATCH", "capability protocol/platform")
    cats = caps.get("categories")
    if not isinstance(cats, list) or len(cats) > 64:
        raise PtpError("PROTOCOL_ERROR", "caps categories")
    for cat in cats:
        if not isinstance(cat, dict) or not isinstance(cat.get("id"), str):
            raise PtpError("PROTOCOL_ERROR", "caps category entry")
    return caps


def migration_plan(sender_caps: dict, receiver_caps: dict) -> set:
    """Categories the sender can export AND the receiver can import (runtime-probed values)."""
    exp = {x["id"] for x in sender_caps["categories"] if x.get("export") and x.get("status") != "unsupported"}
    imp = {x["id"] for x in receiver_caps["categories"] if x.get("import") and x.get("status") != "unsupported"}
    return (exp & imp) & set(c.CATEGORIES)


@dataclass
class Channel:
    reader: asyncio.StreamReader
    writer: asyncio.StreamWriter
    role: str  # sender | receiver (data role of THIS side)
    sas: str
    peer_device: dict
    resume_token: bytes
    resumed: bool
    local_caps: dict = field(default_factory=dict)
    peer_caps: dict = field(default_factory=dict)

    @property
    def plan(self) -> set:
        s, r = (self.local_caps, self.peer_caps) if self.role == "sender" else (self.peer_caps, self.local_caps)
        return migration_plan(s, r)

    async def close(self) -> None:
        try:
            self.writer.close()
            await asyncio.wait_for(self.writer.wait_closed(), 2)
        except Exception:
            pass


async def _mutual_confirm(reader, writer, confirm_cb: ConfirmCb, sas: str, peer: dict) -> None:
    try:
        accepted = bool(await asyncio.wait_for(confirm_cb(sas, peer), c.CONFIRM_TIMEOUT))
    except asyncio.TimeoutError as exc:
        raise PtpError("PEER_TIMEOUT", "local confirmation timed out") from exc
    await c.write_control(writer, {"t": "confirm", "accepted": accepted})
    if not accepted:
        raise PtpError("USER_CANCELLED", "pairing rejected locally")
    msg = await c.expect_control(reader, "confirm", timeout=c.CONFIRM_TIMEOUT)
    if msg.get("accepted") is not True:
        raise PtpError("USER_CANCELLED", "pairing rejected by peer")


async def _exchange_caps(ch: Channel, caps: dict) -> None:
    ch.local_caps = caps
    await c.write_control(ch.writer, {"t": "caps", "caps": caps})
    ch.peer_caps = validate_caps((await c.expect_control(ch.reader, "caps")).get("caps"))


def _device(name: str) -> dict:
    return {"name": name[:64], "platform": "desktop_reference", "model": _platform.machine()[:32]}


class Host:
    """Shows the QR (TLS server). Data role is chosen by the caller."""

    def __init__(self, role: str, device_name: str = "Reference peer", confirm_cb: ConfirmCb = auto_confirm,
                 bind: str = "127.0.0.1", port: int = 0, advertise: Optional[list] = None, ttl: int = c.QR_TTL,
                 caps: Optional[dict] = None):
        assert role in ("sender", "receiver")
        self.role, self.device_name, self.confirm_cb = role, device_name, confirm_cb
        self.bind, self.port, self.advertise, self.ttl = bind, port, advertise, ttl
        self.caps = caps or reference_caps(role)
        self.identity = c.generate_identity()
        self.sid = os.urandom(16)
        self.exp = int(time.time()) + ttl
        self.resume_token: Optional[bytes] = None
        self.last_activity = time.time()
        self.paired_once = False
        self.failures = 0
        self.active = False
        self.destroyed = False
        self._channels: asyncio.Queue = asyncio.Queue()
        self._server = None
        self._tmp = None

    async def start(self) -> "Host":
        self._tmp = tempfile.mkdtemp(prefix="ptp-host-")
        cert, key = Path(self._tmp, "c.pem"), Path(self._tmp, "k.pem")
        cert.write_bytes(self.identity.cert_pem)
        key.write_bytes(self.identity.key_pem)
        os.chmod(key, 0o600)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        ctx.load_cert_chain(cert, key)
        # Key material is loaded; remove it from disk immediately.
        shutil.rmtree(self._tmp, ignore_errors=True)
        self._server = await asyncio.start_server(self._handle, self.bind, self.port, ssl=ctx)
        self.port = self._server.sockets[0].getsockname()[1]
        return self

    @property
    def qr(self) -> c.QrPayload:
        eps = self.advertise or [f"{self.bind}:{self.port}"]
        return c.QrPayload(c.PROTOCOL_VERSION, self.sid, self.exp, eps, self.identity.fingerprint, self.role,
                           "desktop_reference")

    async def accept(self, timeout: Optional[float] = None) -> Channel:
        item = await asyncio.wait_for(self._channels.get(), timeout)
        if isinstance(item, Exception):
            raise item
        return item

    def destroy(self) -> None:
        """Stop accepting connections and drop the session (safe to call from inside a handler)."""
        self.destroyed = True
        if self._server:
            self._server.close()

    async def close(self) -> None:
        self.destroy()
        if self._server:
            if hasattr(self._server, "close_clients"):  # py>=3.13: also drop live channels
                self._server.close_clients()
            try:  # since py3.12 wait_closed() also waits for open connections
                await asyncio.wait_for(self._server.wait_closed(), 5)
            except asyncio.TimeoutError:
                pass

    async def _handle(self, reader, writer) -> None:
        try:
            ch = await self._handshake(reader, writer)
        except PtpError as err:
            await c.send_error(writer, err.code, err.message)
            writer.close()
            if err.code in ("USER_CANCELLED",):
                await self._channels.put(err)
            return
        except Exception:
            writer.close()
            return
        await self._channels.put(ch)

    async def _handshake(self, reader, writer) -> Channel:
        if self.destroyed:
            raise PtpError("PAIRING_EXPIRED", "session closed")
        hello = await c.expect_control(reader, "hello")
        versions = hello.get("versions")
        if not isinstance(versions, list) or c.PROTOCOL_VERSION not in versions:
            raise PtpError("PROTOCOL_VERSION_MISMATCH", "no common protocol version")
        nonce_j = c.unb64u(hello.get("nonce", ""), 16)
        fp = self.identity.fingerprint
        resume = hello.get("resume")
        if self.active:
            raise PtpError("SESSION_BUSY", "another peer is connected")
        if resume is not None:
            ok = (isinstance(resume, dict) and self.resume_token is not None
                  and time.time() - self.last_activity <= c.RESUME_WINDOW
                  and hmac.compare_digest(c.unb64u(resume.get("proof", ""), 32),
                                          c.resume_proof(self.resume_token, fp, nonce_j)))
        else:
            if time.time() > self.exp:
                raise PtpError("PAIRING_EXPIRED", "QR code expired")
            if self.paired_once:
                raise PtpError("AUTHENTICATION_FAILED", "session already used")
            ok = hmac.compare_digest(c.unb64u(hello.get("proof", ""), 32), c.pairing_proof(self.sid, fp, nonce_j))
        if not ok:
            self.failures += 1
            if self.failures >= c.MAX_AUTH_FAILURES:
                self.destroy()  # rate limit: destroy session
            raise PtpError("AUTHENTICATION_FAILED", "bad proof")
        self.active = True
        try:
            nonce_h = os.urandom(16)
            await c.write_control(writer, {"t": "welcome", "version": c.PROTOCOL_VERSION, "nonce": c.b64u(nonce_h),
                                           "device": _device(self.device_name)})
            peer = hello.get("device") if isinstance(hello.get("device"), dict) else {}
            sas = c.sas_code(self.sid, fp, nonce_j, nonce_h)
            if resume is None:
                await _mutual_confirm(reader, writer, self.confirm_cb, sas, peer)
                self.resume_token = os.urandom(32)
                self.paired_once = True
            await c.write_control(writer, {"t": "paired", "resumeToken": c.b64u(self.resume_token),
                                           "resumed": resume is not None})
            ch = Channel(reader, writer, self.role, sas, peer, self.resume_token, resume is not None)
            await _exchange_caps(ch, self.caps)
            self.last_activity = time.time()
            return ch
        except BaseException:
            self.active = False
            raise

    def release(self) -> None:
        """Call when a channel ends so a resume connection can be accepted."""
        self.active = False
        self.last_activity = time.time()


async def join(uri: str, device_name: str = "Reference peer", confirm_cb: ConfirmCb = auto_confirm,
               resume_token: Optional[bytes] = None, caps: Optional[dict] = None,
               connect_timeout: float = 5.0, now: Optional[float] = None) -> Channel:
    qr = c.QrPayload.parse(uri, now=None if resume_token is None else 0)
    role = "sender" if qr.role == "receiver" else "receiver"
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE  # identity is checked by pinning fp below, never by CA
    last_err: Exception = PtpError("PEER_TIMEOUT", "no endpoint reachable")
    for ep in qr.ep:
        host, port = c.parse_endpoint(ep)
        try:
            reader, writer = await asyncio.wait_for(asyncio.open_connection(host, port, ssl=ctx), connect_timeout)
        except (OSError, asyncio.TimeoutError) as exc:
            last_err = PtpError("PEER_TIMEOUT", f"connect failed: {exc.__class__.__name__}")
            continue
        der = writer.get_extra_info("ssl_object").getpeercert(binary_form=True)
        if not der or not hmac.compare_digest(hashlib.sha256(der).digest(), qr.fp):
            writer.close()
            raise PtpError("AUTHENTICATION_FAILED", "host certificate does not match QR fingerprint")
        try:
            nonce_j = os.urandom(16)
            hello = {"t": "hello", "versions": list(c.SUPPORTED_VERSIONS), "nonce": c.b64u(nonce_j),
                     "device": _device(device_name)}
            if resume_token:
                hello["resume"] = {"proof": c.b64u(c.resume_proof(resume_token, qr.fp, nonce_j))}
            else:
                hello["proof"] = c.b64u(c.pairing_proof(qr.sid, qr.fp, nonce_j))
            await c.write_control(writer, hello)
            welcome = await c.expect_control(reader, "welcome")
            if welcome.get("version") not in c.SUPPORTED_VERSIONS:
                raise PtpError("PROTOCOL_VERSION_MISMATCH", "host chose unsupported version")
            nonce_h = c.unb64u(welcome.get("nonce", ""), 16)
            sas = c.sas_code(qr.sid, qr.fp, nonce_j, nonce_h)
            peer = welcome.get("device") if isinstance(welcome.get("device"), dict) else {}
            if not resume_token:
                await _mutual_confirm(reader, writer, confirm_cb, sas, peer)
            paired = await c.expect_control(reader, "paired", timeout=c.CONFIRM_TIMEOUT)
            token = c.unb64u(paired.get("resumeToken", ""), 32)
            ch = Channel(reader, writer, role, sas, peer, token, bool(resume_token))
            await _exchange_caps(ch, caps or reference_caps(role))
            return ch
        except PtpError as err:
            await c.send_error(writer, err.code, err.message)
            writer.close()
            raise
    raise last_err


# ======================================================================= engines
@dataclass
class SourceFile:
    disk_path: Path
    rel_path: str
    category: str
    mime: Optional[str] = None


@dataclass
class TransferReport:
    transfer_id: str
    ok: list = field(default_factory=list)
    failed: dict = field(default_factory=dict)  # i -> code
    skipped: list = field(default_factory=list)
    bytes_on_wire: int = 0
    seconds: float = 0.0
    committed_paths: dict = field(default_factory=dict)


def _stat_ident(p: Path) -> tuple:
    st = p.stat()
    return st.st_size, int(st.st_mtime * 1000)


async def run_sender(ch: Channel, files: list, transfer_id: Optional[str] = None, chunk_size: int = c.DEFAULT_CHUNK,
                     window: int = c.WINDOW, on_progress=None, abort_after_bytes: Optional[int] = None,
                     corrupt_index: Optional[int] = None, cancel: Optional[asyncio.Event] = None) -> TransferReport:
    """Stream files to the peer. abort_after_bytes / corrupt_index are fault-injection hooks for tests."""
    assert ch.role == "sender" and 1 <= chunk_size <= c.MAX_CHUNK
    assert window >= 2 * c.ACK_INTERVAL, "window must exceed the receiver ack interval or the transfer stalls"
    plan = ch.plan
    entries = []
    for idx, sf in enumerate(files):
        size, mtime = _stat_ident(sf.disk_path)
        entries.append(c.FileEntry(idx, c.validate_relative_path(sf.rel_path), size, sf.category, sf.mime, mtime))
    manifest = c.Manifest(transfer_id or c.new_id(), entries)
    report = TransferReport(manifest.transfer_id)
    report.skipped = [e.i for e in entries if e.category not in plan]
    started = time.monotonic()
    await c.write_control(ch.writer, manifest.to_json())
    resp = await c.expect_control(ch.reader, "manifest_resp", max_len=c.MAX_MANIFEST + 1,
                                  timeout=c.CONFIRM_TIMEOUT)
    if resp.get("accept") is not True:
        code = resp.get("error")
        raise PtpError(code if code in c.ERROR_CODES else "INTERNAL_ERROR", "receiver rejected manifest")
    offsets, already = {}, set()
    for item in resp.get("files", []):
        i, off = item.get("i"), item.get("offset")
        if type(i) is not int or not 0 <= i < len(entries) or type(off) is not int or not 0 <= off <= entries[i].size:
            raise PtpError("PROTOCOL_ERROR", "bad manifest_resp entry")
        offsets[i] = off
        if item.get("done"):
            already.add(i)
    report.skipped = sorted(set(range(len(entries))) - set(offsets))
    report.ok.extend(sorted(already))

    acked = {i: off for i, off in offsets.items()}
    sent = dict(acked)
    results: dict = {}
    cond = asyncio.Condition()
    failure: list = []
    peer_report: dict = {}

    async def reader_loop():
        try:
            while True:
                ftype, msg = await c.read_frame(ch.reader, c.MAX_CONTROL + 1)
                if ftype != c.FRAME_CONTROL:
                    raise PtpError("PROTOCOL_ERROR", "receiver sent data")
                t = msg["t"]
                async with cond:
                    if t == "ack" and msg.get("i") in acked and type(msg.get("offset")) is int:
                        acked[msg["i"]] = max(acked[msg["i"]], msg["offset"])
                    elif t == "file_result" and msg.get("i") in acked:
                        results[msg["i"]] = msg.get("status")
                    elif t == "report":
                        peer_report.update(msg)
                        cond.notify_all()
                        return
                    elif t == "cancel":
                        raise PtpError("USER_CANCELLED", "receiver cancelled")
                    cond.notify_all()
        except PtpError as err:
            async with cond:
                failure.append(err)
                cond.notify_all()

    rtask = asyncio.create_task(reader_loop())

    def inflight() -> int:
        return sum(sent.values()) - sum(acked.values())

    async def wait_for(pred):
        async with cond:
            await cond.wait_for(lambda: pred() or failure or (cancel and cancel.is_set()))
        if failure:
            raise failure[0]
        if cancel and cancel.is_set():
            await c.write_control(ch.writer, {"t": "cancel", "reason": "user"})
            raise PtpError("USER_CANCELLED", "cancelled by user")

    wire = 0

    async def send_file(i: int, start: int) -> None:
        nonlocal wire
        e = entries[i]
        src = files[i].disk_path
        if _stat_ident(src) != (e.size, e.mtime):
            await c.write_control(ch.writer, {"t": "file_skip", "i": i, "reason": "FILE_CHANGED"})
            results[i] = "FILE_CHANGED"
            return
        hasher = hashlib.sha256()
        with open(src, "rb") as fh:
            remaining = start
            while remaining:  # re-hash the prefix the receiver already holds
                buf = fh.read(min(remaining, 1024 * 1024))
                hasher.update(buf)
                remaining -= len(buf)
            pos = start
            while True:
                buf = fh.read(chunk_size)
                if not buf:
                    break
                if pos + len(buf) > e.size:
                    buf = buf[: e.size - pos] if pos < e.size else b""
                    if not buf:
                        break
                await wait_for(lambda n=len(buf): inflight() + n <= window)
                hasher.update(buf)
                payload = bytes(b ^ 0xFF for b in buf[:1]) + buf[1:] if (corrupt_index == i and pos == 0) else buf
                await c.write_data(ch.writer, i, pos, payload)
                pos += len(buf)
                sent[i] = pos
                wire += len(buf)
                if on_progress:
                    on_progress(i, pos, e.size)
                if abort_after_bytes is not None and wire >= abort_after_bytes:
                    ch.writer.transport.abort()  # simulate abrupt network loss
                    raise PtpError("NETWORK_INTERRUPTED", "injected fault")
        if pos != e.size or _stat_ident(src) != (e.size, e.mtime):
            await c.write_control(ch.writer, {"t": "file_skip", "i": i, "reason": "FILE_CHANGED"})
            results[i] = "FILE_CHANGED"
            return
        await c.write_control(ch.writer, {"t": "file_end", "i": i, "size": e.size, "sha256": hasher.hexdigest()})

    try:
        todo = [i for i in sorted(offsets) if i not in already]
        for i in todo:
            await send_file(i, offsets[i])
        await wait_for(lambda: all(i in results for i in todo))
        retry = [i for i in todo if results[i] == "hash_mismatch"]
        for i in retry:  # one retry from scratch
            del results[i]
            acked[i] = sent[i] = 0
            corrupt_index = None
            await send_file(i, 0)
        await wait_for(lambda: all(i in results for i in todo))
        await c.write_control(ch.writer, {"t": "done"})
        await wait_for(lambda: bool(peer_report))
    finally:
        rtask.cancel()
    for i in todo:
        if results[i] == "ok":
            report.ok.append(i)
        else:
            report.failed[i] = "HASH_MISMATCH" if results[i] == "hash_mismatch" else str(results[i])
    report.ok.sort()
    report.bytes_on_wire = wire
    report.seconds = time.monotonic() - started
    return report


async def run_receiver(ch: Channel, store: ReceiverStore, on_progress=None,
                       cancel: Optional[asyncio.Event] = None) -> TransferReport:
    assert ch.role == "receiver"
    msg = await c.expect_control(ch.reader, "manifest", max_len=c.MAX_MANIFEST + 1, timeout=c.CONFIRM_TIMEOUT)
    manifest = c.Manifest.from_json(msg)
    plan = ch.plan
    accepted = [e.i for e in manifest.files if e.category in plan]
    offsets = store.prepare(manifest, accepted)
    needed = sum(manifest.files[i].size - off for i, off in offsets.items())
    try:
        free = store.check_capacity(needed)
    except PtpError:
        free = shutil.disk_usage(store.root).free
        await c.write_control(ch.writer, {"t": "manifest_resp", "accept": False, "error": "STORAGE_INSUFFICIENT",
                                          "needed": needed, "available": max(0, free - store.reserve)})
        raise
    await c.write_control(ch.writer, {"t": "manifest_resp", "accept": True, "transferId": manifest.transfer_id,
                                      "files": [{"i": i, "offset": off, "done": store.is_done(i)}
                                                for i, off in sorted(offsets.items())]})
    report = TransferReport(manifest.transfer_id)
    report.skipped = [e.i for e in manifest.files if e.i not in offsets]
    expected = dict(offsets)
    for i in offsets:
        if store.is_done(i):
            report.ok.append(i)
    cur_i, fh, hasher, since_ack = None, None, None, 0
    started = time.monotonic()

    def open_file(i):
        nonlocal cur_i, fh, hasher, since_ack
        if fh:
            fh.close()
        fh, hasher = store.open_part(i, expected[i])
        cur_i, since_ack = i, 0

    try:
        while True:
            if cancel and cancel.is_set():
                await c.write_control(ch.writer, {"t": "cancel", "reason": "user"})
                raise PtpError("USER_CANCELLED", "cancelled by user")
            try:
                ftype, body = await asyncio.wait_for(c.read_frame(ch.reader, c.MAX_DATA_FRAME), c.IDLE_TIMEOUT)
            except asyncio.TimeoutError as exc:
                raise PtpError("PEER_TIMEOUT", "sender idle") from exc
            if ftype == c.FRAME_DATA:
                i, off, payload = body
                if i not in expected or store.is_done(i):
                    raise PtpError("PROTOCOL_ERROR", "data for unaccepted file")
                if off != expected[i]:
                    raise PtpError("RESUME_STATE_INVALID", f"file {i}: offset {off} != {expected[i]}")
                if off + len(payload) > manifest.files[i].size:
                    raise PtpError("MANIFEST_INVALID", "data beyond declared size")
                if cur_i != i:
                    open_file(i)
                fh.write(payload)
                hasher.update(payload)
                expected[i] += len(payload)
                report.bytes_on_wire += len(payload)
                since_ack += len(payload)
                if since_ack >= c.ACK_INTERVAL:
                    store.checkpoint(i, fh, expected[i])
                    await c.write_control(ch.writer, {"t": "ack", "i": i, "offset": expected[i]})
                    since_ack = 0
                if on_progress:
                    on_progress(i, expected[i], manifest.files[i].size)
                continue
            t = body["t"]
            if t == "file_end":
                i = body.get("i")
                if i not in expected or store.is_done(i):
                    raise PtpError("PROTOCOL_ERROR", "file_end for unaccepted file")
                if cur_i != i:
                    open_file(i)
                size_ok = expected[i] == manifest.files[i].size == body.get("size")
                digest = body.get("sha256")
                if size_ok and isinstance(digest, str) and hmac.compare_digest(hasher.hexdigest(), digest.lower()):
                    dest = store.commit(i, fh)
                    report.committed_paths[i] = dest
                    if i not in report.ok:
                        report.ok.append(i)
                    report.failed.pop(i, None)
                    status = "ok"
                else:
                    store.discard(i, fh)
                    expected[i] = 0
                    report.failed[i] = "HASH_MISMATCH"
                    status = "hash_mismatch"
                fh, cur_i = None, None
                await c.write_control(ch.writer, {"t": "ack", "i": i, "offset": expected[i]})
                await c.write_control(ch.writer, {"t": "file_result", "i": i, "status": status})
            elif t == "file_skip":
                i = body.get("i")
                if i in expected:
                    report.failed[i] = "FILE_CHANGED"
                    await c.write_control(ch.writer, {"t": "file_result", "i": i, "status": "FILE_CHANGED"})
            elif t == "done":
                await c.write_control(ch.writer, {"t": "report", "ok": len(report.ok), "failed": len(report.failed),
                                                  "skipped": len(report.skipped)})
                break
            elif t == "cancel":
                raise PtpError("USER_CANCELLED", "sender cancelled")
            else:
                raise PtpError("PROTOCOL_ERROR", f"unexpected {t}")
    finally:
        if fh:
            fh.close()
    report.ok.sort()
    report.seconds = time.monotonic() - started
    return report
