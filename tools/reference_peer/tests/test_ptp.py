"""PTP/1 conformance tests — run for real over TLS 1.3 on 127.0.0.1 (no mocks of the transport)."""
import asyncio
import hashlib
import json
import os
import ssl
import struct
import time
from pathlib import Path

import pytest

from ptp_ref import core as c
from ptp_ref.core import PtpError
from ptp_ref.session import Host, SourceFile, join, reference_caps, run_receiver, run_sender
from ptp_ref.store import ReceiverStore


def sha(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def make(tmp: Path, rel: str, size: int) -> Path:
    p = tmp / "src" / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    with open(p, "wb") as fh:
        left = size
        while left:
            n = min(left, 1 << 20)
            fh.write(os.urandom(n))
            left -= n
    return p


async def pair(host_role="receiver", confirm_h=None, confirm_j=None, host_caps=None, join_caps=None):
    kw = {"confirm_cb": confirm_h} if confirm_h else {}
    h = await Host(host_role, "Host phone", caps=host_caps, **kw).start()
    jkw = {"confirm_cb": confirm_j} if confirm_j else {}
    jt = asyncio.create_task(join(h.qr.to_uri(), "Joiner phone", caps=join_caps, **jkw))
    hc = await h.accept(timeout=10)
    jc = await jt
    return h, hc, jc


def split(hc, jc):
    return (hc, jc) if hc.role == "sender" else (jc, hc)


# ------------------------------------------------------------------ pure units
def test_qr_roundtrip_and_validation():
    qr = c.QrPayload(1, os.urandom(16), int(time.time()) + 60, ["192.168.1.5:4000", "[fe80::1]:4000"],
                     os.urandom(32), "receiver", "android")
    back = c.QrPayload.parse(qr.to_uri())
    assert (back.sid, back.fp, back.ep, back.role) == (qr.sid, qr.fp, qr.ep, qr.role)
    with pytest.raises(PtpError) as e:
        c.QrPayload.parse(qr.to_uri(), now=time.time() + 120)
    assert e.value.code == "PAIRING_EXPIRED"
    bad = [
        "http://pair?d=x",
        "ptp://pair?d=" + c.b64u(json.dumps({**json.loads(c.unb64u(qr.to_uri().split("d=")[1])), "name": "Bob"}).encode()),
        "ptp://pair?d=" + c.b64u(json.dumps({**json.loads(c.unb64u(qr.to_uri().split("d=")[1])), "fp": "AAAA"}).encode()),
        "ptp://pair?d=" + c.b64u(json.dumps({**json.loads(c.unb64u(qr.to_uri().split("d=")[1])), "ep": ["evil.com:1"]}).encode()),
        "ptp://pair?d=" + c.b64u(json.dumps({**json.loads(c.unb64u(qr.to_uri().split("d=")[1])), "v": 9}).encode()),
    ]
    for uri in bad:
        with pytest.raises(PtpError):
            c.QrPayload.parse(uri)


def test_qr_contains_no_pii():
    qr = c.QrPayload(1, os.urandom(16), int(time.time()) + 60, ["10.0.0.2:1"], os.urandom(32), "sender", "ios")
    decoded = json.loads(c.unb64u(qr.to_uri().split("d=")[1]))
    assert set(decoded) == {"v", "sid", "exp", "ep", "fp", "role", "pf", "f"}


@pytest.mark.parametrize("p", ["a.jpg", "DCIM/Camera/IMG_0001.HEIC", "Tài liệu/Hợp đồng 2026.pdf", "x" * 255])
def test_path_ok(p):
    assert c.validate_relative_path(p)


@pytest.mark.parametrize("p", ["", "/etc/passwd", "../x", "a/../../b", "a/./b", "a//b", "a\\b", "C:x", "a\x00b",
                               "trailing.", "trailing ", "x" * 256, "/".join(["d"] * 33), "a\nb"])
def test_path_rejected(p):
    with pytest.raises(PtpError) as e:
        c.validate_relative_path(p)
    assert e.value.code == "MANIFEST_INVALID"


def test_resolve_inside_refuses_symlink(tmp_path):
    root = tmp_path / "inbox"
    (root / "photos").mkdir(parents=True)
    outside = tmp_path / "outside"
    outside.mkdir()
    os.symlink(outside, root / "photos" / "link")
    with pytest.raises(PtpError):
        c.resolve_inside(root, "photos/link/x.jpg")


def test_sas_is_six_digits_and_bound_to_nonces():
    sid, fp = os.urandom(16), os.urandom(32)
    a = c.sas_code(sid, fp, b"1" * 16, b"2" * 16)
    assert len(a) == 6 and a.isdigit()
    assert a == c.sas_code(sid, fp, b"1" * 16, b"2" * 16)  # deterministic: both sides compute the same
    others = {c.sas_code(sid, fp, b"1" * 16, os.urandom(16)) for _ in range(50)}
    assert len(others) > 45  # changes with the host nonce


# ------------------------------------------------------------------ end-to-end over TLS
@pytest.mark.parametrize("host_role", ["receiver", "sender"])
async def test_full_transfer_both_qr_directions(tmp_path, host_role):
    srcs = [
        (make(tmp_path, "DCIM/IMG_0001.jpg", 3_000_123), "DCIM/IMG_0001.jpg", "photos"),
        (make(tmp_path, "Movies/clip.mp4", 9_437_185), "Movies/clip.mp4", "videos"),
        (make(tmp_path, "Tài liệu/Hợp đồng.pdf", 1), "Tài liệu/Hợp đồng.pdf", "documents"),
        (make(tmp_path, "empty.txt", 0), "empty.txt", "documents"),
        (make(tmp_path, "contacts.vcf", 2048), "contacts.vcf", "contacts"),
    ]
    sas_seen = []

    async def confirm(sas, peer):
        sas_seen.append((sas, peer["name"]))
        return True

    h, hc, jc = await pair(host_role, confirm, confirm)
    snd, rcv = split(hc, jc)
    store = ReceiverStore(tmp_path / "inbox", reserve_bytes=0)
    rr, sr = await asyncio.gather(run_receiver(rcv, store),
                                  run_sender(snd, [SourceFile(p, r, cat) for p, r, cat in srcs]))
    assert sas_seen[0][0] == sas_seen[1][0], "both screens must show the same code"
    assert {n for _, n in sas_seen} == {"Host phone", "Joiner phone"}
    assert sr.ok == rr.ok == [0, 1, 2, 3, 4] and not sr.failed and not rr.failed
    for i, (p, r, cat) in enumerate(srcs):
        dest = tmp_path / "inbox" / cat / r
        assert dest.exists() and sha(dest) == sha(p)
    assert not any((tmp_path / "inbox" / ".ptp-partial" / sr.transfer_id).glob("*.part"))
    await hc.close(), await jc.close(), await h.close()


async def test_many_small_files(tmp_path):
    n = 2000  # 10 000 is a device test (docs/TEST_MATRIX.md); kept smaller so CI stays fast
    files = [SourceFile(make(tmp_path, f"f/{k:05d}.txt", 1 + k % 700), f"f/{k:05d}.txt", "documents") for k in range(n)]
    h, hc, jc = await pair()
    rr, sr = await asyncio.gather(run_receiver(hc, ReceiverStore(tmp_path / "in", 0)), run_sender(jc, files))
    assert len(sr.ok) == len(rr.ok) == n
    assert sha(tmp_path / "in/documents/f/01999.txt") == sha(files[-1].disk_path)
    await h.close()


async def test_duplicate_destination_name_gets_suffix(tmp_path):
    (tmp_path / "in/photos").mkdir(parents=True)
    (tmp_path / "in/photos/a.jpg").write_bytes(b"existing user file")
    src = make(tmp_path, "a.jpg", 1000)
    h, hc, jc = await pair()
    await asyncio.gather(run_receiver(hc, ReceiverStore(tmp_path / "in", 0)), run_sender(jc, [SourceFile(src, "a.jpg", "photos")]))
    assert (tmp_path / "in/photos/a.jpg").read_bytes() == b"existing user file"  # never overwritten
    assert sha(tmp_path / "in/photos/a (1).jpg") == sha(src)
    await h.close()


async def test_resume_after_network_loss(tmp_path):
    size = 48 * 1024 * 1024
    src = make(tmp_path, "big.bin", size)
    h, hc, jc = await pair()
    store = ReceiverStore(tmp_path / "in", 0)
    tid = c.new_id()
    results = await asyncio.gather(run_receiver(hc, store),
                                   run_sender(jc, [SourceFile(src, "big.bin", "videos")], transfer_id=tid,
                                              abort_after_bytes=30 * 1024 * 1024), return_exceptions=True)
    assert all(isinstance(r, PtpError) and r.code == "NETWORK_INTERRUPTED" for r in results), results
    h.release()
    # Reconnect with the resume token: no QR scan, no re-confirmation.
    async def must_not_ask(sas, peer):
        raise AssertionError("resume must not ask for confirmation")
    h.confirm_cb = must_not_ask
    jt = asyncio.create_task(join(h.qr.to_uri(), resume_token=jc.resume_token, confirm_cb=must_not_ask))
    hc2 = await h.accept(timeout=10)
    jc2 = await jt
    assert hc2.resumed and jc2.resumed
    rr, sr = await asyncio.gather(run_receiver(hc2, ReceiverStore(tmp_path / "in", 0)),
                                  run_sender(jc2, [SourceFile(src, "big.bin", "videos")], transfer_id=tid))
    assert sr.ok == [0]
    assert 0 < sr.bytes_on_wire < size, "resume must not resend everything"
    assert sr.bytes_on_wire <= size - 16 * 1024 * 1024  # at least two 8 MiB checkpoints survived
    assert sha(tmp_path / "in/videos/big.bin") == sha(src)
    await h.close()


async def test_resume_rejected_with_wrong_token(tmp_path):
    h, hc, jc = await pair()
    await hc.close(), await jc.close()
    h.release()
    with pytest.raises(PtpError) as e:
        await join(h.qr.to_uri(), resume_token=os.urandom(32))
    assert e.value.code == "AUTHENTICATION_FAILED"
    await h.close()


async def test_hash_mismatch_is_detected_and_retried(tmp_path):
    src = make(tmp_path, "doc.pdf", 500_000)
    h, hc, jc = await pair()
    rr, sr = await asyncio.gather(run_receiver(hc, ReceiverStore(tmp_path / "in", 0)),
                                  run_sender(jc, [SourceFile(src, "doc.pdf", "documents")], corrupt_index=0))
    assert sr.ok == [0] and sha(tmp_path / "in/documents/doc.pdf") == sha(src)
    assert sr.bytes_on_wire == 2 * 500_000  # first (corrupted) attempt + retry
    await h.close()


async def test_source_changed_mid_transfer(tmp_path):
    a = make(tmp_path, "a.bin", 3 * 1024 * 1024)
    b = make(tmp_path, "b.bin", 1000)

    def touch_b(i, done, total):
        if i == 0 and done == total:
            os.utime(b, (time.time() + 100, time.time() + 100))
    h, hc, jc = await pair()
    rr, sr = await asyncio.gather(run_receiver(hc, ReceiverStore(tmp_path / "in", 0)),
                                  run_sender(jc, [SourceFile(a, "a.bin", "documents"), SourceFile(b, "b.bin", "documents")],
                                             on_progress=touch_b))
    assert sr.ok == [0] and sr.failed == {1: "FILE_CHANGED"} and rr.failed == {1: "FILE_CHANGED"}
    assert not (tmp_path / "in/documents/b.bin").exists()
    await h.close()


async def test_storage_insufficient(tmp_path):
    src = make(tmp_path, "x.bin", 1000)
    h, hc, jc = await pair()
    store = ReceiverStore(tmp_path / "in", reserve_bytes=1 << 62)
    res = await asyncio.gather(run_receiver(hc, store), run_sender(jc, [SourceFile(src, "x.bin", "documents")]),
                               return_exceptions=True)
    assert [r.code for r in res] == ["STORAGE_INSUFFICIENT", "STORAGE_INSUFFICIENT"]
    await h.close()


async def test_category_not_importable_is_skipped(tmp_path):
    caps = reference_caps("receiver")
    for cat in caps["categories"]:
        if cat["id"] == "contacts":
            cat.update({"import": False, "status": "unsupported"})
    v = make(tmp_path, "c.vcf", 100)
    d = make(tmp_path, "d.txt", 100)
    h, hc, jc = await pair(host_caps=caps)
    rr, sr = await asyncio.gather(run_receiver(hc, ReceiverStore(tmp_path / "in", 0)),
                                  run_sender(jc, [SourceFile(v, "c.vcf", "contacts"), SourceFile(d, "d.txt", "documents")]))
    assert sr.skipped == [0] and sr.ok == [1] and rr.skipped == [0]
    assert not (tmp_path / "in/contacts").exists()
    await h.close()


async def test_cancel_by_sender(tmp_path):
    src = make(tmp_path, "big.bin", 40 * 1024 * 1024)
    ev = asyncio.Event()

    def prog(i, done, total):
        if done > 10 * 1024 * 1024:
            ev.set()
    h, hc, jc = await pair()
    res = await asyncio.gather(run_receiver(hc, ReceiverStore(tmp_path / "in", 0)),
                               run_sender(jc, [SourceFile(src, "big.bin", "videos")], on_progress=prog, cancel=ev),
                               return_exceptions=True)
    assert [r.code for r in res] == ["USER_CANCELLED", "USER_CANCELLED"]
    assert not (tmp_path / "in/videos/big.bin").exists()
    await h.close()


# ------------------------------------------------------------------ security
async def test_wrong_fingerprint_is_rejected_before_sending_anything(tmp_path):
    h = await Host("receiver").start()
    qr = h.qr
    qr.fp = os.urandom(32)  # attacker-in-the-middle / different host
    with pytest.raises(PtpError) as e:
        await join(qr.to_uri())
    assert e.value.code == "AUTHENTICATION_FAILED"
    assert h.failures == 0 and not h.paired_once  # host never saw a hello
    await h.close()


async def test_wrong_session_id_and_rate_limit(tmp_path):
    h = await Host("receiver").start()
    qr = h.qr
    qr.sid = os.urandom(16)
    for _ in range(c.MAX_AUTH_FAILURES):
        with pytest.raises(PtpError) as e:
            await join(qr.to_uri())
        assert e.value.code in ("AUTHENTICATION_FAILED", "NETWORK_INTERRUPTED")
    assert h.destroyed
    with pytest.raises(PtpError):
        await join(h.qr.to_uri())  # even the genuine QR is dead now
    await h.close()


async def test_qr_replay_after_pairing_is_rejected(tmp_path):
    h, hc, jc = await pair()
    uri = h.qr.to_uri()
    await hc.close(), await jc.close()
    h.release()
    with pytest.raises(PtpError) as e:
        await join(uri)
    assert e.value.code == "AUTHENTICATION_FAILED"
    await h.close()


async def test_second_peer_while_busy(tmp_path):
    h, hc, jc = await pair()
    with pytest.raises(PtpError) as e:
        await join(h.qr.to_uri(), resume_token=jc.resume_token)
    assert e.value.code == "SESSION_BUSY"
    await h.close()


async def test_expired_session_rejected_by_host(tmp_path):
    h = await Host("receiver").start()
    uri = h.qr.to_uri()
    h.exp = int(time.time()) - 1
    with pytest.raises(PtpError) as e:
        await join(uri)
    assert e.value.code == "PAIRING_EXPIRED"
    await h.close()


async def test_user_rejects_code(tmp_path):
    async def no(sas, peer):
        return False
    h = await Host("receiver").start()
    res = await asyncio.gather(h.accept(timeout=10), join(h.qr.to_uri(), confirm_cb=no), return_exceptions=True)
    assert all(isinstance(r, PtpError) and r.code == "USER_CANCELLED" for r in res), res
    await h.close()


async def test_path_traversal_manifest_rejected(tmp_path):
    h, hc, jc = await pair()
    evil = {"t": "manifest", "transferId": c.new_id(), "totalBytes": 4,
            "files": [{"i": 0, "path": "../../../evil.sh", "size": 4, "category": "documents"}]}
    await c.write_control(jc.writer, evil)
    with pytest.raises(PtpError) as e:
        await run_receiver(hc, ReceiverStore(tmp_path / "in", 0))
    assert e.value.code == "MANIFEST_INVALID"
    assert not list(tmp_path.rglob("evil.sh"))
    await h.close()


async def test_out_of_order_and_oversize_data_rejected(tmp_path):
    for off, n, code in [(5, 10, "RESUME_STATE_INVALID"), (0, 11, "MANIFEST_INVALID")]:
        h, hc, jc = await pair()
        m = {"t": "manifest", "transferId": c.new_id(), "totalBytes": 10,
             "files": [{"i": 0, "path": "a.bin", "size": 10, "category": "documents"}]}
        await c.write_control(jc.writer, m)
        task = asyncio.create_task(run_receiver(hc, ReceiverStore(tmp_path / f"in{off}", 0)))
        await c.expect_control(jc.reader, "manifest_resp")
        await c.write_data(jc.writer, 0, off, b"x" * n)
        with pytest.raises(PtpError) as e:
            await task
        assert e.value.code == code
        await h.close()


async def test_oversized_frame_before_auth_is_dropped(tmp_path):
    h = await Host("receiver").start()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
    r, w = await asyncio.open_connection("127.0.0.1", h.port, ssl=ctx)
    w.write(struct.pack(">IB", 50 * 1024 * 1024, 1))
    await w.drain()
    with pytest.raises(PtpError) as e:
        await c.read_frame(r, 1 << 16)
    assert e.value.code == "PROTOCOL_ERROR"  # host answered with an error frame, then closed
    await h.close()


async def test_tls12_client_is_refused(tmp_path):
    h = await Host("receiver").start()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE
    ctx.maximum_version = ssl.TLSVersion.TLSv1_2
    with pytest.raises((ssl.SSLError, ConnectionError)):
        await asyncio.open_connection("127.0.0.1", h.port, ssl=ctx)
    await h.close()


async def test_multiple_batches_on_one_channel(tmp_path):
    from ptp_ref.session import receive_all
    a = make(tmp_path, "b1/a.jpg", 200_000)
    b = make(tmp_path, "b2/b.jpg", 300_000)
    h, hc, jc = await pair()
    store = ReceiverStore(tmp_path / "in", 0)

    async def send_batches():
        r1 = await run_sender(jc, [SourceFile(a, "a.jpg", "photos")], more=True)
        r2 = await run_sender(jc, [SourceFile(b, "b.jpg", "photos")], more=False)
        return r1, r2
    reps, (s1, s2) = await asyncio.gather(receive_all(hc, store), send_batches())
    assert len(reps) == 2 and s1.ok == s2.ok == [0] and s1.transfer_id != s2.transfer_id
    assert sha(tmp_path / "in/photos/b.jpg") == sha(b)
    await h.close()


def test_cross_language_vectors_are_current():
    v = json.loads((Path(__file__).resolve().parents[3] / "contracts/test_vectors.json").read_text())
    sid, fp, nj, nh = (c.unb64u(v[k]) for k in ("sid", "fp", "nonceJ", "nonceH"))
    assert c.b64u(c.pairing_proof(sid, fp, nj)) == v["pairingProof"]
    assert c.b64u(c.resume_proof(c.unb64u(v["resumeToken"]), fp, nj)) == v["resumeProof"]
    assert c.sas_code(sid, fp, nj, nh) == v["sas"]
    assert c.QrPayload.parse(v["qrUri"], now=0).sid == sid
    for item in v["validPaths"]:
        assert c.validate_relative_path(item["in"]) == item["nfc"]
    for bad in v["invalidPaths"]:
        with pytest.raises(PtpError):
            c.validate_relative_path(bad)
