"""Receiver-side durable store: partial files, checkpoints, atomic commit, capacity check."""
from __future__ import annotations

import hashlib
import json
import os
import shutil
from pathlib import Path

from .core import Manifest, PtpError, resolve_inside, unique_destination


class ReceiverStore:
    def __init__(self, root: Path, reserve_bytes: int = 256 * 1024 * 1024):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.reserve = reserve_bytes
        self.manifest: Manifest | None = None
        self.state: dict = {}
        self._dir: Path | None = None

    # -- state persistence (JSON written atomically; the app uses SQLite for the same data)
    def _state_path(self) -> Path:
        return self._dir / "state.json"

    def _save(self) -> None:
        tmp = self._dir / "state.json.tmp"
        with open(tmp, "w") as fh:
            json.dump(self.state, fh)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, self._state_path())

    def part_path(self, i: int) -> Path:
        return self._dir / f"{i}.part"

    def prepare(self, manifest: Manifest, accepted: list) -> dict:
        """Return {i: durable_offset} for accepted indices, reusing valid partial state."""
        self.manifest = manifest
        self._dir = self.root / ".ptp-partial" / manifest.transfer_id
        self._dir.mkdir(parents=True, exist_ok=True)
        old = {}
        if self._state_path().exists():
            try:
                old = json.loads(self._state_path().read_text()).get("files", {})
            except (OSError, ValueError):
                old = {}
        files, offsets = {}, {}
        for i in accepted:
            e = manifest.files[i]
            ident = [e.path, e.size, e.mtime, e.category]
            prev = old.get(str(i))
            same = bool(prev) and prev.get("ident") == ident
            part = self.part_path(i)
            if same and prev.get("done"):
                # Committed during an earlier connection of this transfer.
                files[str(i)] = {"ident": ident, "durable": e.size, "done": True, "final": prev.get("final")}
                offsets[i] = e.size
                continue
            durable = int(prev.get("durable", 0)) if same else 0
            if durable and (not part.exists() or part.stat().st_size < durable or durable > e.size):
                durable = 0  # checkpoint not backed by data on disk: restart this file
            if part.exists():
                with open(part, "r+b") as fh:
                    fh.truncate(durable)  # drop bytes written after the last fsync'd checkpoint
            files[str(i)] = {"ident": ident, "durable": durable, "done": False, "final": None}
            offsets[i] = durable
        self.state = {"transferId": manifest.transfer_id, "files": files}
        self._save()
        return offsets

    def is_done(self, i: int) -> bool:
        return bool(self.state["files"][str(i)]["done"])

    def check_capacity(self, needed: int) -> int:
        free = shutil.disk_usage(self.root).free
        if free - self.reserve < needed:
            raise PtpError("STORAGE_INSUFFICIENT", f"need {needed} bytes, {max(0, free - self.reserve)} available")
        return free

    def open_part(self, i: int, offset: int):
        """Open the partial file positioned at offset, with a hasher primed over the durable prefix."""
        part = self.part_path(i)
        fh = open(part, "r+b" if part.exists() else "w+b")
        fh.truncate(offset)
        hasher = hashlib.sha256()
        fh.seek(0)
        remaining = offset
        while remaining:
            buf = fh.read(min(remaining, 1024 * 1024))
            if not buf:
                fh.close()
                raise PtpError("RESUME_STATE_INVALID", "partial shorter than checkpoint")
            hasher.update(buf)
            remaining -= len(buf)
        fh.seek(offset)
        return fh, hasher

    def checkpoint(self, i: int, fh, offset: int) -> None:
        fh.flush()
        os.fsync(fh.fileno())
        self.state["files"][str(i)]["durable"] = offset
        self._save()

    def commit(self, i: int, fh) -> Path:
        e = self.manifest.files[i]
        fh.flush()
        os.fsync(fh.fileno())
        fh.close()
        dest = resolve_inside(self.root, f"{e.category}/{e.path}")
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest = unique_destination(dest)
        os.replace(self.part_path(i), dest)  # atomic within one filesystem
        st = self.state["files"][str(i)]
        st.update(done=True, durable=e.size, final=str(dest.relative_to(self.root.resolve())))
        self._save()
        return dest

    def discard(self, i: int, fh=None) -> None:
        if fh:
            fh.close()
        try:
            self.part_path(i).unlink()
        except FileNotFoundError:
            pass
        self.state["files"][str(i)]["durable"] = 0
        self._save()

    def delete_partials(self) -> None:
        if self._dir and self._dir.exists():
            shutil.rmtree(self._dir)
