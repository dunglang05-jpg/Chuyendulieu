"""CLI: run the reference peer against a phone (or another reference peer) on the same LAN.

  python -m ptp_ref host receive --dir ./inbox --bind 0.0.0.0 --advertise 192.168.1.10
  python -m ptp_ref join send --uri 'ptp://pair?d=...' file1.jpg file2.pdf
"""
import argparse
import asyncio
import mimetypes
import sys
from pathlib import Path

from .session import Host, SourceFile, join, run_receiver, run_sender
from .store import ReceiverStore

CAT_BY_MIME = {"image": "photos", "video": "videos", "audio": "audio"}


def guess(path: Path):
    mime = mimetypes.guess_type(path.name)[0]
    if path.suffix.lower() == ".vcf":
        return "contacts", "text/vcard"
    if path.suffix.lower() == ".ics":
        return "calendar", "text/calendar"
    return CAT_BY_MIME.get((mime or "").split("/")[0], "documents"), mime


async def ask(sas, peer):
    print(f"\nPeer: {peer.get('name')!r} ({peer.get('platform')})  code: {sas}")
    ans = await asyncio.get_running_loop().run_in_executor(None, input, "Codes match on both screens? [y/N] ")
    return ans.strip().lower() == "y"


def progress(i, done, total):
    pct = 100 * done // total if total else 100
    print(f"\r file {i}: {pct:3d}%  ", end="", file=sys.stderr)


async def main(a):
    files = [SourceFile(Path(f), Path(f).name, *guess(Path(f))) for f in a.files]
    if a.mode == "host":
        h = await Host(a.role, a.name, ask, bind=a.bind, port=a.port,
                       advertise=[f"{a.advertise}:{a.port}"] if a.advertise else None).start()
        if a.advertise and a.port == 0:
            h.advertise = [f"{a.advertise}:{h.port}"]
        print("Scan this with the phone app:\n" + h.qr.to_uri())
        ch = await h.accept()
    else:
        ch = await join(a.uri, a.name, ask)
    if ch.role == "receiver":
        rep = await run_receiver(ch, ReceiverStore(Path(a.dir), reserve_bytes=0), progress)
    else:
        rep = await run_sender(ch, files, on_progress=progress)
    await ch.close()
    mbps = rep.bytes_on_wire / 1e6 / rep.seconds if rep.seconds else 0
    print(f"\nok={len(rep.ok)} failed={rep.failed} skipped={rep.skipped} "
          f"bytes={rep.bytes_on_wire} time={rep.seconds:.2f}s ({mbps:.1f} MB/s measured on this link)")


ap = argparse.ArgumentParser(prog="ptp_ref")
ap.add_argument("mode", choices=["host", "join"])
ap.add_argument("role", choices=["send", "receive"])
ap.add_argument("files", nargs="*")
ap.add_argument("--uri")
ap.add_argument("--dir", default="./ptp-inbox")
ap.add_argument("--bind", default="127.0.0.1")
ap.add_argument("--port", type=int, default=0)
ap.add_argument("--advertise", help="LAN IP to put in the QR")
ap.add_argument("--name", default="Reference peer")
args = ap.parse_args()
args.role = "sender" if args.role == "send" else "receiver"
asyncio.run(main(args))
