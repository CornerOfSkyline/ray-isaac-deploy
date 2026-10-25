"""Configuration loader with schema validation for ray-isaac-deploy."""
import yaml
import json
import os
import copy
from pathlib import Path
from typing import Any, Dict, Optional


class ConfigError(Exception):
    """Configuration validation error."""
    pass


def _deep_merge(base: dict, override: dict) -> dict:
    """Deep merge two dictionaries."""
    result = copy.deepcopy(base)
    for key, value in override.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = _deep_merge(result[key], value)
        else:
            result[key] = copy.deepcopy(value)
    return result


class ClusterConfig:
    """Unified configuration for Ray + Isaac Sim deployment.

    Loads from YAML, validates required fields, and provides helper
    accessors for commonly used values.
    """

    REQUIRED_TOP_KEYS = ['hosts', 'ray', 'isaacsim', 'visualization']

    def __init__(self, config_path: str, profile_path: Optional[str] = None):
        self._raw = self._load_yaml(config_path)
        if profile_path:
            profile = self._load_yaml(profile_path)
            self._raw = _deep_merge(self._raw, profile)
        self._validate()

    def _load_yaml(self, path: str) -> dict:
        if not os.path.isfile(path):
            raise ConfigError(f"Config file not found: {path}")
        with open(path, 'r') as f:
            return yaml.safe_load(f) or {}

    def _validate(self):
        missing = [k for k in self.REQUIRED_TOP_KEYS if k not in self._raw]
        if missing:
            raise ConfigError(f"Missing required config sections: {missing}")

    # --- Hosts ---
    @property
    def a800_ssh(self) -> str:
        h = self._raw['hosts']['a800']
        return f"ssh -p {h['ssh_port']} {h['ssh_user']}@{h['ssh_host']}"

    @property
    def gpu4090_ssh(self) -> str:
        h = self._raw['hosts']['gpu4090']
        return f"ssh -p {h['ssh_port']} {h['ssh_user']}@{h['ssh_host']}"

    # --- Ray ---
    @property
    def ray_version(self) -> str:
        return self._raw['ray']['version']

    @property
    def ray_head_address(self) -> str:
        return self._raw['ray']['head']['address']

    @property
    def ray_gcs_port(self) -> int:
        return self._raw['ray']['head']['gcs_port']

    @property
    def ray_worker_address(self) -> str:
        return self._raw['ray']['worker']['address']

    @property
    def ray_head_node_manager(self) -> int:
        return self._raw['ray']['head']['node_manager_port']

    @property
    def ray_worker_node_manager(self) -> int:
        return self._raw['ray']['worker']['node_manager_port']

    @property
    def ray_worker_gpu_count(self) -> int:
        return self._raw['ray']['worker']['gpu_count']

    # --- Isaac Sim ---
    @property
    def isaac_install_path(self) -> str:
        return self._raw['isaacsim']['install_path']

    @property
    def isaac_signal_port(self) -> int:
        return self._raw['isaacsim']['signal_port']

    @property
    def isaac_stream_port(self) -> int:
        return self._raw['isaacsim']['stream_port']

    @property
    def isaac_public_ip(self) -> str:
        return self._raw['isaacsim']['public_ip']

    @property
    def isaac_kit_args(self) -> list:
        extra = self._raw['isaacsim'].get('kit_extra_args', [])
        return [
            '--allow-root',
            f'--/exts/omni.kit.livestream.app/primaryStream/signalPort={self.isaac_signal_port}',
            f'--/exts/omni.kit.livestream.app/primaryStream/streamPort={self.isaac_stream_port}',
            f'--/exts/omni.kit.livestream.app/primaryStream/publicIp={self.isaac_public_ip}',
        ] + extra

    # --- Visualization ---
    @property
    def vnc_binary(self) -> str:
        return self._raw['visualization']['vnc']['binary']

    @property
    def vnc_display(self) -> str:
        return self._raw['visualization']['vnc']['display']

    @property
    def vnc_port(self) -> int:
        return self._raw['visualization']['vnc']['port']

    @property
    def vnc_geometry(self) -> str:
        return self._raw['visualization']['vnc']['geometry']

    @property
    def vnc_args(self) -> list:
        v = self._raw['visualization']['vnc']
        return [
            v['display'], '-geometry', v['geometry'], '-depth', str(v.get('depth', 24)),
        ] + v.get('extra_args', [])

    @property
    def novnc_port(self) -> int:
        return self._raw['visualization']['novnc']['port']

    @property
    def novnc_path(self) -> str:
        return self._raw['visualization']['novnc']['path']

    @property
    def websockify_bin(self) -> str:
        return self._raw['visualization']['novnc']['websockify']

    @property
    def webrtc_client_path(self) -> str:
        return self._raw['visualization']['webrtc_client']['path']

    @property
    def webrtc_client_flags(self) -> list:
        return self._raw['visualization']['webrtc_client'].get('electron_flags', [])

    @property
    def webrtc_cdp_port(self) -> int:
        return self._raw['visualization']['webrtc_client'].get('cdp_port', 9222)

    @property
    def webrtc_auto_connect_script(self) -> str:
        return self._raw['visualization']['webrtc_client'].get('auto_connect_script', '')

    # --- Operations ---
    @property
    def pid_dir(self) -> str:
        return self._raw.get('operations', {}).get('pid_dir', '/tmp/ray-isaac-deploy')

    @property
    def log_dir(self) -> str:
        return self._raw.get('operations', {}).get('log_dir', '/tmp/ray-isaac-deploy/logs')

    @property
    def windows_browser_port(self) -> int:
        return self._raw['hosts']['windows'].get('browser_port', 16006)

    # --- Raw access ---
    def get(self, *keys, default=None):
        """Deep get from raw config."""
        val = self._raw
        for k in keys:
            if isinstance(val, dict):
                val = val.get(k)
            else:
                return default
        return val if val is not None else default

    def to_dict(self) -> dict:
        return copy.deepcopy(self._raw)


def load_config(profile: str = "verified-20261025") -> ClusterConfig:
    """Load configuration with the specified profile."""
    base_dir = Path(__file__).parent.parent.parent
    example_path = base_dir / "config" / "cluster.example.yaml"
    profile_path = base_dir / "profiles" / f"{profile}.yaml"

    # Use example as base, profile as override
    if example_path.exists():
        config = ClusterConfig(str(example_path), str(profile_path))
    else:
        config = ClusterConfig(str(profile_path))

    return config