"""Health check diagnostics for Ray + Isaac Sim deployment."""
import subprocess
import time
from .config import ClusterConfig


class Diagnostics:
    """Layered health checks for the full deployment."""

    def __init__(self, config: ClusterConfig):
        self.config = config

    def _ssh_4090(self, cmd: str, timeout: int = 10) -> str:
        try:
            r = subprocess.run(f"{self.config.gpu4090_ssh} '{cmd}'",
                              shell=True, capture_output=True, text=True, timeout=timeout)
            return r.stdout.strip()
        except:
            return ""

    def _ssh_a800(self, cmd: str, timeout: int = 10) -> str:
        try:
            r = subprocess.run(f"{self.config.a800_ssh} '{cmd}'",
                              shell=True, capture_output=True, text=True, timeout=timeout)
            return r.stdout.strip()
        except:
            return ""

    def check_ssh_connectivity(self) -> dict:
        """Verify SSH connectivity to both machines."""
        a800 = self._ssh_a800("echo OK", timeout=10)
        g4090 = self._ssh_4090("echo OK", timeout=10)
        return {
            "a800_reachable": a800 == "OK",
            "gpu4090_reachable": g4090 == "OK",
        }

    def check_ray_cluster(self) -> dict:
        """Check Ray cluster health from the 4090 (worker perspective)."""
        output = self._ssh_4090(
            "python3 -c \""
            "import ray; "
            "ray.init(address='127.0.0.2:6379', ignore_reinit_error=True, logging_level='ERROR'); "
            "resources = ray.cluster_resources(); "
            "nodes = ray.nodes(); "
            "alive = [n for n in nodes if n['Alive']]; "
            "print(f'ALIVE_NODES:{len(alive)}'); "
            "print(f'TOTAL_GPU:{resources.get(\"GPU\",0)}'); "
            "for n in alive: "
            "    print(f'NODE:{n[\"NodeName\"]} GPU:{n.get(\"Resources\",{}).get(\"GPU\",0)}'); "
            "ray.shutdown()\"", timeout=15
        )

        result = {"raw": output, "alive_nodes": 0, "nodes": [], "healthy": False}
        for line in output.split('\n'):
            if line.startswith('ALIVE_NODES:'):
                result['alive_nodes'] = int(line.split(':')[1])
            elif line.startswith('TOTAL_GPU:'):
                result['total_gpu'] = float(line.split(':')[1])
            elif line.startswith('NODE:'):
                parts = line.split()
                if len(parts) >= 2:
                    result['nodes'].append({
                        'name': parts[0].split(':')[1],
                        'gpu': int(parts[1].split(':')[1]) if 'GPU:' in parts[1] else 0
                    })

        result['healthy'] = result['alive_nodes'] >= 2
        return result

    def check_visualization_layer1_vnc(self) -> dict:
        """Layer 1: Xvnc process + VNC port."""
        out = self._ssh_4090(
            f"ps -p $(pgrep -f 'Xvnc.*{self.config.vnc_display}') > /dev/null 2>&1 && echo OK; "
            f"ss -tlnp | grep -q ':{self.config.vnc_port} ' && echo PORT_OK"
        )
        return {
            "xvnc_running": "OK" in out,
            "vnc_port_listening": "PORT_OK" in out,
        }

    def check_visualization_layer2_novnc(self) -> dict:
        """Layer 2: noVNC accessible."""
        out = self._ssh_4090(
            f"ss -tlnp | grep -q ':{self.config.novnc_port} ' && echo PORT_OK; "
            f"curl -s -o /dev/null -w '%{{http_code}}' http://127.0.0.1:{self.config.novnc_port}/vnc.html 2>/dev/null"
        )
        return {
            "novnc_listening": "PORT_OK" in out,
            "novnc_http": out.replace("PORT_OK", "").strip(),
        }

    def check_visualization_layer3_isaac_sim(self) -> dict:
        """Layer 3: Isaac Sim loaded + signaling."""
        out = self._ssh_4090(
            f"ss -tlnp | grep -q ':{self.config.isaac_signal_port} ' && echo SIGNAL_OK; "
            f"grep -qi 'app loaded\\|Full Streaming App is loaded' {self.config.log_dir}/isaac-stream.log 2>/dev/null && echo APP_LOADED"
        )
        return {
            "signal_port_listening": "SIGNAL_OK" in out,
            "app_loaded": "APP_LOADED" in out,
        }

    def check_visualization_layer4_webrtc(self) -> dict:
        """Layer 4: WebRTC client + stream."""
        out = self._ssh_4090(
            f"pgrep -c isaacsim-webrtc; "
            f"grep -c 'Stream started.*status=success' {self.config.log_dir}/webrtc-client.log 2>/dev/null; "
            f"ss -ulnp | grep -c ':{self.config.isaac_stream_port} '",
            timeout=10
        )
        lines = out.split('\n')
        return {
            "webrtc_client_running": int(lines[0] or 0) > 0,
            "stream_success": int(lines[1] or 0) > 0,
            "udp_media_port_bound": int(lines[2] or 0) > 0 if len(lines) > 2 else False,
        }

    def check_gpu(self) -> dict:
        """Check GPU usage on 4090."""
        out = self._ssh_4090(
            "nvidia-smi --query-gpu=index,memory.used,memory.total,utilization.gpu --format=csv,noheader"
        )
        gpus = []
        for line in out.split('\n'):
            parts = [p.strip().replace(' MiB', '').replace(' %', '') for p in line.split(', ')]
            if len(parts) >= 4:
                gpus.append({
                    "index": parts[0],
                    "memory_used_mb": parts[1],
                    "memory_total_mb": parts[2],
                    "utilization_pct": parts[3],
                })
        return {"gpus": gpus, "count": len(gpus)}

    def check_ray_worker_process(self) -> dict:
        """Check Ray Worker process is alive on 4090."""
        out = self._ssh_4090("pgrep -c raylet")
        count = int(out.strip() or 0)
        return {"raylet_running": count > 0, "raylet_count": count}

    def run_full_diagnostics(self) -> dict:
        """Run all health checks."""
        return {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "ssh_connectivity": self.check_ssh_connectivity(),
            "ray_cluster": self.check_ray_cluster(),
            "ray_worker": self.check_ray_worker_process(),
            "gpu": self.check_gpu(),
            "visualization": {
                "layer1_vnc": self.check_visualization_layer1_vnc(),
                "layer2_novnc": self.check_visualization_layer2_novnc(),
                "layer3_isaac_sim": self.check_visualization_layer3_isaac_sim(),
                "layer4_webrtc": self.check_visualization_layer4_webrtc(),
            }
        }

    def visualization_ready(self) -> tuple[bool, str]:
        """Check if visualization is fully ready (all layers pass)."""
        v = self.run_full_diagnostics()['visualization']
        checks = [
            ('VNC running', v['layer1_vnc'].get('xvnc_running', False)),
            ('VNC port', v['layer1_vnc'].get('vnc_port_listening', False)),
            ('noVNC listening', v['layer2_novnc'].get('novnc_listening', False)),
            ('Isaac Sim signal', v['layer3_isaac_sim'].get('signal_port_listening', False)),
            ('Isaac Sim loaded', v['layer3_isaac_sim'].get('app_loaded', False)),
            ('WebRTC client', v['layer4_webrtc'].get('webrtc_client_running', False)),
            ('Stream success', v['layer4_webrtc'].get('stream_success', False)),
            ('UDP media', v['layer4_webrtc'].get('udp_media_port_bound', False)),
        ]
        failed = [name for name, ok in checks if not ok]
        return len(failed) == 0, ', '.join(failed) if failed else 'All checks passed'