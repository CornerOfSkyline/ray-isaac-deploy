"""SSH tunnel management for Ray + Isaac Sim deployment."""
import subprocess
import time
import os
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class SSHTunnel:
    """Represents a single SSH port forwarding tunnel."""
    name: str
    local_port: int
    remote_host: str
    remote_port: int
    target_ssh: str  # e.g., "ssh -p 46602 zjf@180.97.68.228"
    pid: Optional[int] = None

    def start(self) -> int:
        """Start the tunnel, return PID."""
        cmd = (
            f"ssh -NT "
            f"-L 127.0.0.1:{self.local_port}:{self.remote_host}:{self.remote_port} "
            f"-o ExitOnForwardFailure=yes "
            f"-o ServerAliveInterval=30 "
            f"-o ServerAliveCountMax=3 "
            f"-o StrictHostKeyChecking=accept-new "
            f"{self._extract_ssh_args()}"
        )
        proc = subprocess.Popen(cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.pid = proc.pid
        time.sleep(1)
        return proc.pid

    def _extract_ssh_args(self) -> str:
        """Extract -p, user@host from full SSH command."""
        parts = self.target_ssh.split()
        return ' '.join(parts[1:])  # Skip 'ssh'

    def is_alive(self) -> bool:
        """Check if tunnel process is still running."""
        if self.pid is None:
            return False
        try:
            os.kill(self.pid, 0)
            return True
        except OSError:
            return False


class TunnelManager:
    """Manages SSH tunnels between Ray Head and Worker."""

    def __init__(self, config):
        self.config = config
        self.tunnels: list[SSHTunnel] = []

    def setup_worker_to_head(self):
        """Set up 4090 Worker -> A800 Head tunnel (GCS)."""
        tunnels_data = self.config.get('ssh_tunnels', 'worker_to_head', default=[])
        for t in tunnels_data:
            tunnel = SSHTunnel(
                name=t.get('name', 'unknown'),
                local_port=t['local_port'],
                remote_host=t['remote_host'],
                remote_port=t['remote_port'],
                target_ssh=self.config.gpu4090_ssh,
            )
            self.tunnels.append(tunnel)

    def setup_head_to_worker(self):
        """Set up A800 Head -> 4090 Worker tunnels (RPC/Agent)."""
        tunnels_data = self.config.get('ssh_tunnels', 'head_to_worker', default=[])
        for t in tunnels_data:
            local_ports = self._parse_port_range(t.get('local_ports', ''))
            remote_ports = self._parse_port_range(t.get('remote_ports', ''))
            for lp, rp in zip(local_ports, remote_ports):
                tunnel = SSHTunnel(
                    name=f"{t.get('name')}_{lp}",
                    local_port=lp,
                    remote_host=t['remote_host'],
                    remote_port=rp,
                    target_ssh=self.config.a800_ssh,
                )
                self.tunnels.append(tunnel)

    def _parse_port_range(self, spec: str) -> list:
        """Parse '23002-23007' into [23002, ..., 23007]."""
        if '-' in spec:
            start, end = spec.split('-')
            return list(range(int(start), int(end) + 1))
        return [int(spec)]

    def start_all(self, target: str = 'all'):
        """Start all tunnels for specified target."""
        started = []
        for t in self.tunnels:
            if not t.is_alive():
                pid = t.start()
                started.append((t.name, pid))
        return started

    def stop_all(self):
        """Stop all managed tunnels."""
        for t in self.tunnels:
            if t.is_alive() and t.pid:
                try:
                    os.kill(t.pid, 15)  # SIGTERM
                except OSError:
                    pass

    def status(self) -> dict:
        """Return status of all tunnels."""
        return {t.name: t.is_alive() for t in self.tunnels}