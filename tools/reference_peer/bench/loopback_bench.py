"""Loopback benchmark: one large file through the real TLS 1.3 stack on 127.0.0.1.

Measures the reference implementation on THIS machine only. It says nothing about phone Wi-Fi throughput.
Usage: python bench/loopback_bench.py [size_mb]
"""
import asyncio, hashlib, os, resource, sys, tempfile, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ptp_ref.session import Host, SourceFile, join, run_receiver, run_sender
from ptp_ref.store import ReceiverStore

async def main(size_mb):
    tmp = Path(tempfile.mkdtemp(prefix="ptp-bench-"))
    src = tmp / "big.bin"
    with open(src, "wb") as fh:
        for _ in range(size_mb):
            fh.write(os.urandom(1 << 20))
    rss0 = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    h = await Host("receiver").start()
    jt = asyncio.create_task(join(h.qr.to_uri()))
    hc = await h.accept(10); jc = await jt
    t0 = time.monotonic()
    rr, sr = await asyncio.gather(run_receiver(hc, ReceiverStore(tmp / "in", 0)), run_sender(jc, [SourceFile(src, "big.bin", "videos")]))
    dt = time.monotonic() - t0
    rss1 = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    ok = hashlib.sha256(src.read_bytes()).hexdigest() == hashlib.sha256((tmp / "in/videos/big.bin").read_bytes()).hexdigest() if size_mb <= 2048 else "skipped"
    print(f"size={size_mb} MiB time={dt:.2f}s throughput={size_mb/dt:.1f} MiB/s (sender+receiver in one process, "
          f"both hashing) peak_rss_before={rss0//1024} MiB peak_rss_after={rss1//1024} MiB sha256_match={ok}")
    await hc.close(); await jc.close(); await h.close()
    import shutil; shutil.rmtree(tmp)

asyncio.run(main(int(sys.argv[1]) if len(sys.argv) > 1 else 1024))
