"""PTP/1 primitives: constants, errors, crypto helpers, QR payload, framing, path rules, manifest validation.

Reference implementation of docs/PROTOCOL_v1.md. Used for conformance tests and as a desktop test peer.
"""
from __future__ import annotations

import asyncio
import base64
import datetime as _dt
import hashlib
import hmac
import ipaddress
import json
import os
import secrets
import struct
import time
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional
from urllib.parse import parse_qs, urlparse

# ---------------------------------------------------------------- constants
PROTOCOL_VERSION = 1
SUPPORTED_VERSIONS = (1,)
FRAME_CONTROL = 0x01
FRAME_DATA = 0x02
MAX_CONTROL = 64 * 1024
MAX_MANIFEST = 16 * 1024 * 1024
MAX_CHUNK = 4 * 1024 * 1024
LARGE_CONTROL = ("manifest", "manifest_resp")  # O(files); everything else is capped at MAX_CONTROL
DATA_HEADER = struct.Struct(">IQ")
MAX_DATA_FRAME = 1 + DATA_HEADER.size + MAX_CHUNK
MAX_FILES = 100_000
MAX_FILE_SIZE = 1 << 40
DEFAULT_CHUNK = 1024 * 1024
ACK_INTERVAL = 8 * 1024 * 1024
WINDOW = 32 * 1024 * 1024
QR_TTL = 300
RESUME_WINDOW = 15 * 60
HANDSHAKE_TIMEOUT = 20
CONFIRM_TIMEOUT = 120
IDLE_TIMEOUT = 60
MAX_AUTH_FAILURES = 5
CATEGORIES = ("contacts", "photos", "videos", "audio", "documents", "calendar")
PLATFORMS = ("android", "ios", "desktop_reference")

ERROR_CODES = frozenset(
    "PEER_TIMEOUT PAIRING_EXPIRED AUTHENTICATION_FAILED PROTOCOL_VERSION_MISMATCH PROTOCOL_ERROR "
    "MANIFEST_INVALID CAPABILITY_UNAVAILABLE PERMISSION_DENIED STORAGE_INSUFFICIENT FILE_CHANGED "
    "HASH_MISMATCH NETWORK_INTERRUPTED RESUME_STATE_INVALID IMPORT_REQUIRES_USER_ACTION "
    "PLATFORM_RESTRICTION SESSION_BUSY USER_CANCELLED INTERNAL_ERROR".split()
)


class PtpError(Exception):
    def __init__(self, code: str, message: str = ""):
        assert code in ERROR_CODES, code
        super().__init__(f"{code}: {message}" if message else code)
        self.code = code
        self.message = message


# ---------------------------------------------------------------- encoding / crypto
def b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def unb64u(text: str, expected_len: Optional[int] = None) -> bytes:
    if not isinstance(text, str) or len(text) > 4096:
        raise PtpError("PROTOCOL_ERROR", "bad base64 field")
    try:
        raw = base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))
    except Exception as exc:  # binascii.Error
        raise PtpError("PROTOCOL_ERROR", "bad base64 field") from exc
    if expected_len is not None and len(raw) != expected_len:
        raise PtpError("PROTOCOL_ERROR", "bad field length")
    return raw


def _hmac(key: bytes, *parts: bytes) -> bytes:
    return hmac.new(key, b"".join(parts), hashlib.sha256).digest()


def pairing_proof(sid: bytes, fp: bytes, nonce_j: bytes) -> bytes:
    return _hmac(sid, b"ptp1/proof", fp, nonce_j)


def resume_proof(token: bytes, fp: bytes, nonce_j: bytes) -> bytes:
    return _hmac(token, b"ptp1/resume", fp, nonce_j)


def sas_code(sid: bytes, fp: bytes, nonce_j: bytes, nonce_h: bytes) -> str:
    h = _hmac(sid, b"ptp1/sas", fp, nonce_j, nonce_h)
    return f"{int.from_bytes(h[:4], 'big') % 1_000_000:06d}"


@dataclass
class EphemeralIdentity:
    cert_pem: bytes
    key_pem: bytes
    cert_der: bytes

    @property
    def fingerprint(self) -> bytes:
        return hashlib.sha256(self.cert_der).digest()


def generate_identity() -> EphemeralIdentity:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID

    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "ptp-ephemeral")])
    now = _dt.datetime.now(_dt.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(int.from_bytes(secrets.token_bytes(16), "big") >> 1)
        .not_valid_before(now - _dt.timedelta(hours=1))
        .not_valid_after(now + _dt.timedelta(days=2))
        .sign(key, hashes.SHA256())
    )
    return EphemeralIdentity(
        cert_pem=cert.public_bytes(serialization.Encoding.PEM),
        key_pem=key.private_bytes(
            serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()
        ),
        cert_der=cert.public_bytes(serialization.Encoding.DER),
    )


# ---------------------------------------------------------------- QR payload
@dataclass
class QrPayload:
    v: int
    sid: bytes
    exp: int
    ep: list
    fp: bytes
    role: str
    pf: str
    f: list = field(default_factory=list)

    def to_uri(self) -> str:
        body = {"v": self.v, "sid": b64u(self.sid), "exp": self.exp, "ep": self.ep,
                "fp": b64u(self.fp), "role": self.role, "pf": self.pf, "f": self.f}
        uri = "ptp://pair?d=" + b64u(json.dumps(body, separators=(",", ":")).encode())
        assert len(uri) <= 1024
        return uri

    @staticmethod
    def parse(uri: str, now: Optional[float] = None) -> "QrPayload":
        if not isinstance(uri, str) or len(uri) > 1024:
            raise PtpError("PROTOCOL_ERROR", "QR too long")
        u = urlparse(uri)
        if u.scheme != "ptp" or u.netloc != "pair":
            raise PtpError("PROTOCOL_ERROR", "not a PTP QR code")
        d = parse_qs(u.query).get("d", [None])[0]
        if not d:
            raise PtpError("PROTOCOL_ERROR", "missing payload")
        try:
            obj = json.loads(unb64u(d))
        except ValueError as exc:
            raise PtpError("PROTOCOL_ERROR", "payload not JSON") from exc
        if not isinstance(obj, dict):
            raise PtpError("PROTOCOL_ERROR", "payload not object")
        allowed = {"v", "sid", "exp", "ep", "fp", "role", "pf", "f", "ap"}
        if set(obj) - allowed or not {"v", "sid", "exp", "ep", "fp", "role", "pf"} <= set(obj):
            raise PtpError("PROTOCOL_ERROR", "unexpected QR fields")
        if not isinstance(obj["v"], int) or obj["v"] not in SUPPORTED_VERSIONS:
            raise PtpError("PROTOCOL_VERSION_MISMATCH", f"QR version {obj['v']!r}")
        if not isinstance(obj["exp"], int):
            raise PtpError("PROTOCOL_ERROR", "bad exp")
        if (now if now is not None else time.time()) > obj["exp"]:
            raise PtpError("PAIRING_EXPIRED", "QR code expired")
        ep = obj["ep"]
        if not isinstance(ep, list) or not 1 <= len(ep) <= 8:
            raise PtpError("PROTOCOL_ERROR", "bad endpoints")
        for e in ep:
            parse_endpoint(e)
        if obj["role"] not in ("sender", "receiver") or obj["pf"] not in PLATFORMS:
            raise PtpError("PROTOCOL_ERROR", "bad role/platform")
        flags = obj.get("f", [])
        if not isinstance(flags, list) or len(flags) > 16 or not all(isinstance(x, str) and len(x) <= 32 for x in flags):
            raise PtpError("PROTOCOL_ERROR", "bad flags")
        if "ap" in obj:  # host's app-only hotspot; validated like the app does, then ignored (the PC is on the LAN)
            ap = obj["ap"]
            if (not isinstance(ap, dict) or set(ap) != {"s", "k", "sec"} or not isinstance(ap["s"], str)
                    or not 1 <= len(ap["s"].encode()) <= 32 or not isinstance(ap["k"], str)
                    or not 8 <= len(ap["k"]) <= 63 or any(not 0x20 <= ord(c) <= 0x7e for c in ap["k"])
                    or ap["sec"] not in ("wpa2", "wpa3")):
                raise PtpError("PROTOCOL_ERROR", "bad hotspot info")
        return QrPayload(obj["v"], unb64u(obj["sid"], 16), obj["exp"], ep, unb64u(obj["fp"], 32),
                         obj["role"], obj["pf"], flags)


def parse_endpoint(text: str) -> tuple:
    if not isinstance(text, str) or len(text) > 64:
        raise PtpError("PROTOCOL_ERROR", "bad endpoint")
    try:
        if text.startswith("["):
            host, _, port = text[1:].partition("]:")
        else:
            host, _, port = text.rpartition(":")
        ipaddress.ip_address(host)
        p = int(port)
    except ValueError as exc:
        raise PtpError("PROTOCOL_ERROR", "bad endpoint") from exc
    if not 1 <= p <= 65535:
        raise PtpError("PROTOCOL_ERROR", "bad port")
    return host, p


# ---------------------------------------------------------------- framing
async def write_control(writer: asyncio.StreamWriter, msg: dict) -> None:
    body = json.dumps(msg, separators=(",", ":"), ensure_ascii=False).encode()
    writer.write(struct.pack(">IB", len(body) + 1, FRAME_CONTROL) + body)
    await writer.drain()


async def write_data(writer: asyncio.StreamWriter, index: int, offset: int, payload: bytes) -> None:
    header = struct.pack(">IB", 1 + DATA_HEADER.size + len(payload), FRAME_DATA) + DATA_HEADER.pack(index, offset)
    writer.write(header)
    writer.write(payload)
    await writer.drain()


async def read_frame(reader: asyncio.StreamReader, max_len: int) -> tuple:
    try:
        (length,) = struct.unpack(">I", await reader.readexactly(4))
        if length < 1 or length > max_len:
            raise PtpError("PROTOCOL_ERROR", f"frame length {length} out of bounds")
        body = await reader.readexactly(length)
    except (asyncio.IncompleteReadError, ConnectionError) as exc:
        raise PtpError("NETWORK_INTERRUPTED", "peer closed connection") from exc
    ftype = body[0]
    if ftype == FRAME_CONTROL:
        if length - 1 > MAX_MANIFEST:
            raise PtpError("PROTOCOL_ERROR", "control frame too large")
        try:
            msg = json.loads(body[1:].decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as exc:
            raise PtpError("PROTOCOL_ERROR", "control frame not JSON") from exc
        if not isinstance(msg, dict) or not isinstance(msg.get("t"), str):
            raise PtpError("PROTOCOL_ERROR", "control frame missing type")
        if msg["t"] not in LARGE_CONTROL and length - 1 > MAX_CONTROL:
            raise PtpError("PROTOCOL_ERROR", "control frame too large")
        if msg["t"] == "error":
            code = msg.get("code")
            raise PtpError(code if code in ERROR_CODES else "INTERNAL_ERROR", str(msg.get("message", ""))[:200])
        return FRAME_CONTROL, msg
    if ftype == FRAME_DATA:
        if length - 1 <= DATA_HEADER.size or length - 1 - DATA_HEADER.size > MAX_CHUNK:
            raise PtpError("PROTOCOL_ERROR", "bad data frame")
        index, offset = DATA_HEADER.unpack_from(body, 1)
        return FRAME_DATA, (index, offset, memoryview(body)[1 + DATA_HEADER.size:])
    raise PtpError("PROTOCOL_ERROR", f"unknown frame type {ftype}")


async def expect_control(reader, t: str, max_len: int = MAX_CONTROL + 1, timeout: float = HANDSHAKE_TIMEOUT) -> dict:
    try:
        ftype, msg = await asyncio.wait_for(read_frame(reader, max_len), timeout)
    except asyncio.TimeoutError as exc:
        raise PtpError("PEER_TIMEOUT", f"waiting for {t}") from exc
    if ftype != FRAME_CONTROL:
        raise PtpError("PROTOCOL_ERROR", f"expected {t}, got data")
    if msg["t"] == "cancel":
        raise PtpError("USER_CANCELLED", "peer cancelled")
    if msg["t"] != t:
        raise PtpError("PROTOCOL_ERROR", f"expected {t}, got {msg['t']}")
    return msg


async def send_error(writer, code: str, message: str = "") -> None:
    try:
        await asyncio.wait_for(write_control(writer, {"t": "error", "code": code, "message": message[:200]}), 2)
    except Exception:
        pass


# ---------------------------------------------------------------- path rules
_FORBIDDEN = set('\\:*?"<>|')


def validate_relative_path(path: str) -> str:
    if not isinstance(path, str) or not path:
        raise PtpError("MANIFEST_INVALID", "empty path")
    p = unicodedata.normalize("NFC", path)
    if len(p.encode("utf-8")) > 1024 or p.startswith("/"):
        raise PtpError("MANIFEST_INVALID", "path too long or absolute")
    segments = p.split("/")
    if len(segments) > 32:
        raise PtpError("MANIFEST_INVALID", "path too deep")
    for seg in segments:
        if not seg or seg in (".", "..") or len(seg.encode("utf-8")) > 255:
            raise PtpError("MANIFEST_INVALID", "bad path segment")
        if seg[-1] in " ." or any(ord(c) < 0x20 or ord(c) == 0x7F or c in _FORBIDDEN for c in seg):
            raise PtpError("MANIFEST_INVALID", "forbidden character in path")
    return p


def resolve_inside(root: Path, rel: str) -> Path:
    """Join a validated relative path to root; refuse escapes and symlinked components."""
    root_resolved = root.resolve()
    target = root_resolved.joinpath(*rel.split("/"))
    cur = root_resolved
    for part in rel.split("/"):
        cur = cur / part
        if cur.is_symlink():
            raise PtpError("MANIFEST_INVALID", "symlink in destination path")
    resolved = target.resolve(strict=False)
    if resolved != root_resolved and root_resolved not in resolved.parents:
        raise PtpError("MANIFEST_INVALID", "path escapes destination")
    return resolved


def unique_destination(path: Path) -> Path:
    if not path.exists():
        return path
    stem, suffix = path.stem, path.suffix
    for n in range(1, 10_000):
        cand = path.with_name(f"{stem} ({n}){suffix}")
        if not cand.exists():
            return cand
    raise PtpError("INTERNAL_ERROR", "too many name collisions")


# ---------------------------------------------------------------- manifest
@dataclass
class FileEntry:
    i: int
    path: str
    size: int
    category: str
    mime: Optional[str] = None
    mtime: Optional[int] = None

    def to_json(self) -> dict:
        return {"i": self.i, "path": self.path, "size": self.size, "category": self.category,
                "mime": self.mime, "mtime": self.mtime}


@dataclass
class Manifest:
    transfer_id: str
    files: list

    @property
    def total_bytes(self) -> int:
        return sum(f.size for f in self.files)

    def to_json(self) -> dict:
        return {"t": "manifest", "transferId": self.transfer_id, "totalBytes": self.total_bytes,
                "files": [f.to_json() for f in self.files]}

    @staticmethod
    def from_json(msg: dict) -> "Manifest":
        tid = msg.get("transferId")
        unb64u(tid if isinstance(tid, str) else "", 16)
        files = msg.get("files")
        if not isinstance(files, list) or len(files) > MAX_FILES:
            raise PtpError("MANIFEST_INVALID", "bad file list")
        out, seen = [], set()
        for idx, f in enumerate(files):
            if not isinstance(f, dict) or set(f) - {"i", "path", "size", "category", "mime", "mtime", "sha256"}:
                raise PtpError("MANIFEST_INVALID", "bad file entry")
            size = f.get("size")
            if f.get("i") != idx or type(size) is not int or not 0 <= size <= MAX_FILE_SIZE:
                raise PtpError("MANIFEST_INVALID", "bad index or size")
            if f.get("category") not in CATEGORIES:
                raise PtpError("MANIFEST_INVALID", "unknown category")
            path = validate_relative_path(f.get("path"))
            key = (f["category"], path.casefold())
            if key in seen:
                raise PtpError("MANIFEST_INVALID", "duplicate path")
            seen.add(key)
            mime, mtime = f.get("mime"), f.get("mtime")
            if mime is not None and (not isinstance(mime, str) or len(mime) > 255):
                raise PtpError("MANIFEST_INVALID", "bad mime")
            if mtime is not None and type(mtime) is not int:
                raise PtpError("MANIFEST_INVALID", "bad mtime")
            out.append(FileEntry(idx, path, size, f["category"], mime, mtime))
        if msg.get("totalBytes") != sum(e.size for e in out):
            raise PtpError("MANIFEST_INVALID", "totalBytes mismatch")
        return Manifest(tid, out)


def new_id(n: int = 16) -> str:
    return b64u(os.urandom(n))
