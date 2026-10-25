"""Lifecycle management: start/stop/status for all components."""
import subprocess
import time
import os
from typing import Optional

from .config import ClusterConfig
from .process_registry import ProcessRegistry


class ComponentLifecycle:
    """Manages start/stop/status for a single component."""

    def __init__(self, name: str, registry: ProcessRegistry, config: ClusterConfig):
        self.name = name
        self.registry = registry
        self.config = config

    def status(self) -> dict:
        """Check component status."""
        entry = self.registry.get(self.name)
        if entry and entry.is_alive():
            return {"name": self.name, "status": "running", "pid": entry.pid}
        if entry:
            return {"name": self.name, "status": "stopped", "pid": entry.pid}
        return {"name": self.name, "status": "unknown"}

    def _is_port_listening(self, port: int, host: str = "0.0.0.0") -> bool:
        """Check if a port is being listened on."""
        try:
            result = subprocess.run(
                f"ss -tlnp | grep -q ':{port} '",
                shell=True, capture_output=True, timeout=5
            )
            return result.returncode == 0
        except:
            return False

    def _wait_for_port(self, port: int, timeout: int = 120, step: int = 2) -> bool:
        """Wait for a port to be listening."""
        for i in range(timeout // step):
            if self._is_port_listening(port):
                return True
            time.sleep(step)
        return False

    def _wait_for_log_pattern(self, logfile: str, pattern: str, timeout: int = 120) -> bool:
        """Wait for a pattern to appear in a log file."""
        for i in range(timeout // 2):
            if os.path.isfile(logfile):
                try:
                    with open(logfile) as f:
                        if pattern in f.read():
                            return True
                except:
                    pass
            time.sleep(2)
        return False

    def _run_remote(self, cmd: str, ssh_target: str = None) -> subprocess.CompletedProcess:
        """Run a command on a remote machine via SSH."""
        if ssh_target is None:
            return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
        full_cmd = f"{ssh_target} '{cmd}'"
        return subprocess.run(full_cmd, shell=True, capture_output=True, text=True, timeout=30)

    def start(self) -> dict:
        """Start this component. Override in subclasses."""
        raise NotImplementedError

    def stop(self) -> dict:
        """Stop this component."""
        result = self.registry.stop(self.name)
        return {"name": self.name, "stopped": result}

    def verify(self) -> dict:
        """Verify this component is fully operational."""
        raise NotImplementedError