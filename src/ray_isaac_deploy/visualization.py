"""Visualization stack lifecycle: Xvnc -> noVNC -> WebRTC Client -> CDP auto-connect."""
import subprocess
import time
import os

from .config import ClusterConfig
from .process_registry import ProcessRegistry
from .lifecycle import ComponentLifecycle


class VisualizationStack:
    """Manages the full visualization pipeline on the 4090."""

    def __init__(self, config: ClusterConfig, registry: ProcessRegistry, ssh_target: str):
        self.config = config
        self.registry = registry
        self.ssh = ssh_target
        # SSH target for the 4090 (where visualization runs)

    def _remote(self, cmd: str, timeout: int = 15) -> subprocess.CompletedProcess:
        full = f"{self.ssh} '{cmd}'"
        return subprocess.run(full, shell=True, capture_output=True, text=True, timeout=timeout)

    def _remote_bg(self, cmd: str, logfile: str) -> int:
        """Run command in background via nohup, return PID."""
        full = f"{self.ssh} 'nohup {cmd} > {logfile} 2>&1 & echo \\$!'"
        result = subprocess.run(full, shell=True, capture_output=True, text=True, timeout=10)
        try:
            return int(result.stdout.strip())
        except:
            return 0

    # --- Xvnc ---
    def start_vnc(self) -> dict:
        """Start Xvnc virtual desktop."""
        if self.registry.is_registered_running("xvnc"):
            return {"name": "xvnc", "status": "already_running"}

        lib_path = self.config.get('visualization', 'vnc', 'library_path', default='')
        ld_cmd = f"export LD_LIBRARY_PATH={lib_path}:$LD_LIBRARY_PATH" if lib_path else ""
        vnc_args = ' '.join(self.config.vnc_args)
        vnc_cmd = f"{ld_cmd} && {self.config.vnc_binary} {vnc_args}"

        port = self.config.vnc_port
        log = f"{self.config.log_dir}/xvnc.log"
        self._remote(f"mkdir -p {self.config.log_dir}")

        pid = self._remote_bg(vnc_cmd, log)
        if pid > 0:
            time.sleep(3)
            if self._is_port_listening(port):
                self.registry.register("xvnc", pid, exe=self.config.vnc_binary,
                                       cmdline=vnc_cmd[:200], log_path=log)
                return {"name": "xvnc", "status": "started", "pid": pid, "port": port}

        return {"name": "xvnc", "status": "failed", "pid": pid}

    def stop_vnc(self) -> dict:
        self.registry.stop("xvnc")
        # Clean up lock files
        display = self.config.vnc_display.replace(':', '')
        self._remote(f"rm -f /tmp/.X{display}-lock /tmp/.X11-unix/X{display} 2>/dev/null")
        return {"name": "xvnc", "status": "stopped"}

    # --- noVNC ---
    def start_novnc(self) -> dict:
        """Start websockify + noVNC."""
        if self.registry.is_registered_running("novnc"):
            return {"name": "novnc", "status": "already_running"}

        cmd = (f"{self.config.websockify_bin} --web={self.config.novnc_path} "
               f"{self.config.novnc_port} 127.0.0.1:{self.config.vnc_port}")
        log = f"{self.config.log_dir}/novnc.log"

        pid = self._remote_bg(cmd, log)
        if pid > 0:
            time.sleep(2)
            if self._is_port_listening(self.config.novnc_port):
                self.registry.register("novnc", pid, exe=self.config.websockify_bin,
                                       cmdline=cmd[:200], log_path=log)
                return {"name": "novnc", "status": "started", "pid": pid, "port": self.config.novnc_port}

        return {"name": "novnc", "status": "failed", "pid": pid}

    def stop_novnc(self) -> dict:
        self.registry.stop("novnc")
        return {"name": "novnc", "status": "stopped"}

    # --- Isaac Sim ---
    def start_isaac_sim(self) -> dict:
        """Start Isaac Sim streaming server."""
        if self.registry.is_registered_running("isaac-sim"):
            return {"name": "isaac-sim", "status": "already_running"}

        kit_args = ' '.join(self.config.isaac_kit_args)
        cmd = (f"cd {self.config.isaac_install_path} && "
               f"OMNI_KIT_ACCEPT_EULA=Y ACCEPT_EULA=Y "
               f"./isaac-sim.streaming.sh {kit_args}")
        log = f"{self.config.log_dir}/isaac-stream.log"

        pid = self._remote_bg(cmd, log)
        if pid > 0:
            # Wait for app to load (looking for loaded indicator)
            loaded = self._wait_for_log_remote(
                log, self.config.get('isaacsim', 'app_loaded_indicator', default='app loaded'),
                timeout=120
            )
            if loaded or self._is_port_listening(self.config.isaac_signal_port):
                self.registry.register("isaac-sim", pid,
                                       exe=f"{self.config.isaac_install_path}/kit/kit",
                                       cmdline=cmd[:200], log_path=log)
                return {"name": "isaac-sim", "status": "started", "pid": pid,
                        "signal_port": self.config.isaac_signal_port,
                        "app_loaded": loaded}

        return {"name": "isaac-sim", "status": "starting", "pid": pid}

    def stop_isaac_sim(self) -> dict:
        self.registry.stop("isaac-sim")
        return {"name": "isaac-sim", "status": "stopped"}

    # --- WebRTC Client ---
    def start_webrtc_client(self) -> dict:
        """Start the Linux WebRTC Streaming Client on the VNC display."""
        if self.registry.is_registered_running("webrtc-client"):
            return {"name": "webrtc-client", "status": "already_running"}

        flags = ' '.join(self.config.webrtc_client_flags)
        display = self.config.vnc_display
        cmd = (f"DISPLAY={display} {self.config.webrtc_client_path} {flags}")
        log = f"{self.config.log_dir}/webrtc-client.log"

        pid = self._remote_bg(cmd, log)
        if pid > 0:
            time.sleep(8)
            if self._is_port_listening(self.config.webrtc_cdp_port):
                self.registry.register("webrtc-client", pid,
                                       exe=self.config.webrtc_client_path,
                                       cmdline=cmd[:200], log_path=log)
                return {"name": "webrtc-client", "status": "started", "pid": pid,
                        "cdp_port": self.config.webrtc_cdp_port}

        return {"name": "webrtc-client", "status": "failed", "pid": pid}

    def stop_webrtc_client(self) -> dict:
        self.registry.stop("webrtc-client")
        return {"name": "webrtc-client", "status": "stopped"}

    # --- CDP Auto-connect ---
    def auto_connect(self) -> dict:
        """Run CDP auto-connect to link WebRTC client to Isaac Sim."""
        if not self._is_port_listening(self.config.webrtc_cdp_port):
            return {"name": "cdp-auto-connect", "status": "cdp_not_ready"}

        script = self.config.webrtc_auto_connect_script
        if not script or not os.path.exists(script):
            # Fall back to inline Python CDP connect
            result = self._remote(
                f"python3 -c \""
                f"import json,asyncio,urllib.request,websockets;"
                f"tabs=json.load(urllib.request.urlopen('http://127.0.0.1:{self.config.webrtc_cdp_port}/json'));"
                f"page=next(t for t in tabs if t.get('type')=='page');"
                f"async def m():"
                f"  async with websockets.connect(page['webSocketDebuggerUrl']) as w:"
                f"    expr='localStorage.setItem(\\\"server\\\",\\\"{self.config.isaac_public_ip}\\\");"
                f"localStorage.setItem(\\\"signalPort\\\",\\\"{self.config.isaac_signal_port}\\\");"
                f"localStorage.setItem(\\\"streamPort\\\",\\\"{self.config.isaac_stream_port}\\\");"
                f"location.search=\\\\"?server={self.config.isaac_public_ip}&signalPort={self.config.isaac_signal_port}&streamPort={self.config.isaac_stream_port}&autoConnect\\\"';"
                f"    await w.send(json.dumps({{'id':1,'method':'Runtime.evaluate','params':{{'expression':expr}}}}));"
                f"    print(json.loads(await w.recv()));"
                f"asyncio.get_event_loop().run_until_complete(m())\"",
                timeout=15
            )
        else:
            result = self._remote(f"python3 {script} {self.config.isaac_public_ip} "
                                 f"{self.config.isaac_signal_port} {self.config.isaac_stream_port} 1920 1080")

        return {"name": "cdp-auto-connect", "status": "executed", "output": result.stdout[:200]}

    # --- Composite actions ---
    def start_all(self) -> dict:
        """Start full visualization stack in correct dependency order."""
        results = {}

        results['xvnc'] = self.start_vnc()
        if results['xvnc']['status'] not in ('started', 'already_running'):
            return {"error": "VNC failed to start", "results": results}

        results['novnc'] = self.start_novnc()
        results['isaac-sim'] = self.start_isaac_sim()
        time.sleep(5)
        results['webrtc-client'] = self.start_webrtc_client()
        time.sleep(3)
        results['cdp-auto-connect'] = self.auto_connect()

        return results

    def stop_all(self) -> dict:
        """Stop full visualization stack."""
        results = {}
        results['webrtc-client'] = self.stop_webrtc_client()
        results['isaac-sim'] = self.stop_isaac_sim()
        results['novnc'] = self.stop_novnc()
        results['xvnc'] = self.stop_vnc()
        return results

    def status_all(self) -> dict:
        """Check status of all visualization components."""
        return {
            'xvnc': {'running': self.registry.is_registered_running('xvnc'),
                     'port': f"{self.config.vnc_port}"},
            'novnc': {'running': self.registry.is_registered_running('novnc'),
                      'port': f"{self.config.novnc_port}"},
            'isaac-sim': {'running': self.registry.is_registered_running('isaac-sim'),
                          'signal_port': f"{self.config.isaac_signal_port}"},
            'webrtc-client': {'running': self.registry.is_registered_running('webrtc-client'),
                              'cdp_port': f"{self.config.webrtc_cdp_port}"},
        }

    # --- Helpers ---
    def _is_port_listening(self, port: int) -> bool:
        try:
            result = self._remote(f"ss -tlnp | grep -q ':{port} '", timeout=5)
            return result.returncode == 0
        except:
            return False

    def _wait_for_log_remote(self, logfile: str, pattern: str, timeout: int = 120) -> bool:
        cmd = (
            f"for i in $(seq 1 $(({timeout}/2))); do "
            f"  if grep -qi '{pattern}' {logfile} 2>/dev/null; then echo found; break; fi; "
            f"  sleep 2; done"
        )
        try:
            result = self._remote(cmd, timeout=timeout + 10)
            return 'found' in result.stdout
        except:
            return False