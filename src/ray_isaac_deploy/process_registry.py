"""Process registry - PID-based process tracking without fuzzy pkill."""
import os
import json
import time
from dataclasses import dataclass, asdict
from typing import Optional


@dataclass
class ProcessEntry:
    """Tracked process entry with full identity for PID reuse protection."""
    name: str
    pid: int
    start_time: float
    proc_start_time: int = 0   # /proc/PID/stat starttime (jiffies)
    uid: int = 0                # /proc/PID/status Uid
    exe: str = ""              # /proc/PID/exe target
    cmdline: str = ""          # /proc/PID/cmdline
    work_dir: str = ""
    log_path: str = ""
    status: str = "unknown"    # running, stopped, failed

    def is_alive(self) -> bool:
        try:
            os.kill(self.pid, 0)
            return True
        except (OSError, ProcessLookupError):
            return False


class ProcessRegistry:
    """Tracks managed processes by PID, avoiding fuzzy name matching for kills."""

    def __init__(self, state_dir: str = "/tmp/ray-isaac-deploy"):
        self.state_dir = state_dir
        os.makedirs(state_dir, exist_ok=True)
        self._state_file = os.path.join(state_dir, "process_registry.json")
        self._entries: dict[str, ProcessEntry] = {}
        self._load()

    def _load(self):
        if os.path.isfile(self._state_file):
            with open(self._state_file) as f:
                data = json.load(f)
                for name, d in data.items():
                    self._entries[name] = ProcessEntry(**d)

    def save(self):
        with open(self._state_file, 'w') as f:
            json.dump({k: asdict(v) for k, v in self._entries.items()}, f, indent=2)

    def register(self, name: str, pid: int, exe: str = "", cmdline: str = "",
                 work_dir: str = "", log_path: str = ""):
        """Register a new process or update existing."""
        if not exe and pid > 0:
            try:
                exe = os.readlink(f"/proc/{pid}/exe")
            except (OSError, FileNotFoundError):
                pass
        if not cmdline and pid > 0:
            try:
                with open(f"/proc/{pid}/cmdline", 'rb') as f:
                    cmdline = f.read().decode().replace('\x00', ' ').strip()
            except (OSError, FileNotFoundError):
                pass

        self._entries[name] = ProcessEntry(
            name=name, pid=pid, start_time=time.time(),
            exe=exe, cmdline=cmdline[:300], work_dir=work_dir,
            log_path=log_path, status="running"
        )
        self.save()

    def get(self, name: str) -> Optional[ProcessEntry]:
        return self._entries.get(name)

    def stop(self, name: str, force: bool = False):
        """Stop a tracked process. SIGTERM first, SIGKILL if force."""
        entry = self._entries.get(name)
        if entry is None:
            return False

        signal = 9 if force else 15
        try:
            os.kill(entry.pid, signal)
            if not force:
                # Wait for graceful shutdown
                for _ in range(30):
                    if not entry.is_alive():
                        entry.status = "stopped"
                        self.save()
                        return True
                    time.sleep(1)
                # Force kill if still alive
                os.kill(entry.pid, 9)
        except (OSError, ProcessLookupError):
            pass

        entry.status = "stopped"
        self.save()
        return True

    def cleanup_stale(self):
        """Remove entries for processes that are no longer running."""
        stale = [name for name, e in self._entries.items() if not e.is_alive()]
        for name in stale:
            self._entries[name].status = "stopped"
            del self._entries[name]
        self.save()
        return stale

    def list_all(self) -> dict:
        """List all tracked processes with status."""
        result = {}
        for name, entry in self._entries.items():
            alive = entry.is_alive()
            if not alive and entry.status == "running":
                entry.status = "stopped"
            result[name] = {
                "pid": entry.pid,
                "alive": alive,
                "status": entry.status,
                "start_time": entry.start_time,
                "cmdline": entry.cmdline[:200],
            }
        return result

    def is_registered_running(self, name: str) -> bool:
        entry = self._entries.get(name)
        return entry is not None and entry.is_alive()