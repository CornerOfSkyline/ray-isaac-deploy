"""Configuration loader with JSON Schema validation for ray-isaac-deploy."""
import yaml
import json
import os
import copy
import re
from pathlib import Path
from typing import Any, Dict, Optional, List


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


def _load_json_schema(schema_path: str) -> dict:
    """Load JSON Schema from file."""
    with open(schema_path) as f:
        schema = json.load(f)
    if not isinstance(schema, dict) or 'properties' not in schema:
        raise ConfigError(f"Invalid JSON Schema at {schema_path}: missing 'properties'")
    return schema


def _validate_with_schema(instance: dict, schema: dict):
    """Validate configuration against JSON Schema using jsonschema if available."""
    try:
        import jsonschema
        validator = jsonschema.Draft202012Validator(schema)
        errors = sorted(validator.iter_errors(instance), key=lambda e: e.path)
        if errors:
            msgs = []
            for err in errors[:10]:  # Limit to first 10 errors
                path = '.'.join(str(p) for p in err.path) if err.path else '(root)'
                msgs.append(f"  {path}: {err.message}")
            raise ConfigError("Schema validation failed:\n" + '\n'.join(msgs))
    except ImportError:
        # jsonschema not installed; do basic validation
        _basic_validate(instance, schema)


def _basic_validate(instance: dict, schema: dict):
    """Fallback validation without jsonschema library."""
    props = schema.get('properties', {})
    required = schema.get('required', [])
    for key in required:
        if key not in instance:
            raise ConfigError(f"Missing required key: {key}")
    for key, value in instance.items():
        if key in props:
            ps = props[key]
            if 'pattern' in ps:
                pat = ps['pattern']
                if isinstance(value, str) and not re.match(pat, value):
                    raise ConfigError(f"Key '{key}' value '{value}' does not match pattern {pat}")
            if 'enum' in ps and value not in ps['enum']:
                raise ConfigError(f"Key '{key}' value '{value}' not in {ps['enum']}")
            if 'const' in ps and value != ps['const']:
                raise ConfigError(f"Key '{key}' must be {ps['const']}, got {value}")
            if ps.get('type') == 'object' and isinstance(value, dict):
                _basic_validate(value, ps)


class ClusterConfig:
    """Unified configuration for Ray + Isaac Sim deployment.

    Loads from YAML profile, validates against JSON Schema.
    Example config provides defaults; profile provides overrides.
    """

    REQUIRED_TOP_KEYS = ['hosts', 'ray', 'isaacsim', 'visualization']

    def __init__(self, config_path: str, profile_path: Optional[str] = None,
                 schema_path: Optional[str] = None):
        self._raw = self._load_yaml(config_path)
        if profile_path and os.path.isfile(profile_path):
            profile = self._load_yaml(profile_path)
            self._raw = _deep_merge(self._raw, profile)
        self._validate()

        # Optional schema validation
        if schema_path is None:
            base = Path(__file__).parent.parent.parent
            schema_path = base / "config" / "cluster.schema.json"
        if os.path.isfile(str(schema_path)):
            schema = _load_json_schema(str(schema_path))
            _validate_with_schema(self._raw, schema)

    def _load_yaml(self, path: str) -> dict:
        if not os.path.isfile(path):
            raise ConfigError(f"Config file not found: {path}")
        with open(path, 'r') as f:
            data = yaml.safe_load(f)
        return data if isinstance(data, dict) else {}

    def _validate(self):
        missing = [k for k in self.REQUIRED_TOP_KEYS if k not in self._raw]
        if missing:
            raise ConfigError(f"Missing required config sections: {missing}")
        # Check port uniqueness across all services
        ports = {}
        for path, field_name in [
            (['ray', 'head', 'gcs_port'], 'ray.head.gcs_port'),
            (['ray', 'head', 'node_manager_port'], 'ray.head.node_manager_port'),
            (['ray', 'head', 'object_manager_port'], 'ray.head.object_manager_port'),
            (['ray', 'worker', 'node_manager_port'], 'ray.worker.node_manager_port'),
            (['ray', 'worker', 'object_manager_port'], 'ray.worker.object_manager_port'),
            (['isaacsim', 'signal_port'], 'isaacsim.signal_port'),
            (['isaacsim', 'stream_port'], 'isaacsim.stream_port'),
            (['visualization', 'vnc', 'port'], 'visualization.vnc.port'),
            (['visualization', 'novnc', 'port'], 'visualization.novnc.port'),
            (['visualization', 'webrtc_client', 'cdp_port'], 'visualization.webrtc_client.cdp_port'),
        ]:
            val = self.get(*path, default=None)
            if val is not None and val != 0:
                if val in ports:
                    raise ConfigError(f"Port {val} conflict: '{field_name}' and '{ports[val]}'")
                ports[val] = field_name

    # --- Accessors ---
    def get(self, *keys, default=None):
        val = self._raw
        for k in keys:
            if isinstance(val, dict):
                val = val.get(k)
            else:
                return default
            if val is None:
                return default
        return val

    @property
    def ray_version(self) -> str: return self._raw['ray']['version']

    @property
    def ray_head_address(self) -> str: return self._raw['ray']['head']['address']

    @property
    def ray_gcs_port(self) -> int: return self._raw['ray']['head']['gcs_port']

    @property
    def ray_worker_address(self) -> str: return self._raw['ray']['worker']['address']

    @property
    def ray_worker_gpu_count(self) -> int: return self._raw['ray']['worker']['gpu_count']

    @property
    def isaac_install_path(self) -> str: return self._raw['isaacsim']['install_path']

    @property
    def isaac_signal_port(self) -> int: return self._raw['isaacsim']['signal_port']

    @property
    def isaac_stream_port(self) -> int: return self._raw['isaacsim']['stream_port']

    @property
    def isaac_public_ip(self) -> str: return self._raw['isaacsim']['public_ip']

    @property
    def isaac_kit_args(self) -> List[str]:
        """Kit args WITHOUT --allow-root (that's added at execution time)."""
        return [
            f'--/exts/omni.kit.livestream.app/primaryStream/signalPort={self.isaac_signal_port}',
            f'--/exts/omni.kit.livestream.app/primaryStream/streamPort={self.isaac_stream_port}',
            f'--/exts/omni.kit.livestream.app/primaryStream/publicIp={self.isaac_public_ip}',
        ]

    @property
    def vnc_port(self) -> int: return self._raw['visualization']['vnc']['port']

    @property
    def vnc_display(self) -> str: return self._raw['visualization']['vnc']['display']

    @property
    def novnc_port(self) -> int: return self._raw['visualization']['novnc']['port']

    @property
    def novnc_path(self) -> str: return self._raw['visualization']['novnc']['path']

    @property
    def websockify_bin(self) -> str: return self._raw['visualization']['novnc']['websockify']

    @property
    def webrtc_client_path(self) -> str: return self._raw['visualization']['webrtc_client']['path']

    @property
    def webrtc_cdp_port(self) -> int: return self._raw['visualization']['webrtc_client']['cdp_port']

    @property
    def webrtc_client_flags(self) -> List[str]: return self._raw['visualization']['webrtc_client']['electron_flags']

    @property
    def log_dir(self) -> str:
        return self._raw.get('operations', {}).get('log_dir', '/tmp/ray-isaac-deploy/logs')

    def to_dict(self) -> dict:
        return copy.deepcopy(self._raw)

    # SSH connection strings (computed)
    @property
    def a800_ssh(self) -> str:
        h = self._raw['hosts']['a800']
        return f"ssh -p {h['ssh_port']} {h['ssh_user']}@{h['ssh_host']}"

    @property
    def gpu4090_ssh(self) -> str:
        h = self._raw['hosts']['gpu4090']
        return f"ssh -p {h['ssh_port']} {h['ssh_user']}@{h['ssh_host']}"


def load_config(profile_name: str = "verified-20261025") -> ClusterConfig:
    """Load configuration with the specified profile."""
    base_dir = Path(__file__).parent.parent.parent
    profile_path = base_dir / "profiles" / f"{profile_name}.yaml"
    if not profile_path.exists():
        raise ConfigError(f"Profile not found: {profile_path}")
    return ClusterConfig(str(profile_path))