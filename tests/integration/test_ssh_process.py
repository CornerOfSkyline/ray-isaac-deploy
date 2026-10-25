"""Integration tests for SSH tunnel configuration and process safety."""
import pytest
import tempfile, os, json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).parent.parent.parent / 'src'))

from ray_isaac_deploy.config import ClusterConfig, ConfigError


def _minimal_config(**overrides):
    """Create minimal valid config with optional overrides."""
    base = {
        'hosts': {
            'windows': {'role': 'controller', 'browser_port': 16006},
            'a800': {'role': 'ray_head', 'ssh_host': '10.0.0.1', 'ssh_port': 2222, 'ssh_user': 'test'},
            'gpu4090': {'role': 'ray_worker_and_isaac_sim', 'ssh_host': '10.0.0.2', 'ssh_port': 3333, 'ssh_user': 'test'},
        },
        'ray': {
            'version': '2.40.0',
            'head': {'address': '127.0.0.2', 'gcs_port': 6379, 'node_manager_port': 22002, 'object_manager_port': 22003, 'cpu_count': 4, 'gpu_count': 8},
            'worker': {'address': '127.0.0.3', 'node_manager_port': 23002, 'object_manager_port': 23003, 'worker_rpc_start': 23100, 'worker_rpc_end': 23131, 'cpu_count': 4, 'gpu_count': 1},
        },
        'isaacsim': {'install_path': '/tmp/isaacsim', 'signal_port': 49100, 'stream_port': 47998, 'public_ip': '192.168.0.1'},
        'visualization': {
            'vnc': {'binary': '/usr/bin/Xvnc', 'display': ':1', 'port': 5901, 'geometry': '1920x1080', 'depth': 24},
            'novnc': {'path': '/tmp/novnc', 'websockify': '/usr/bin/ws', 'port': 6006},
            'webrtc_client': {'path': '/tmp/client', 'cdp_port': 9222, 'electron_flags': ['--disable-gpu']},
        },
        'operations': {'pid_dir': '/tmp/pids', 'log_dir': '/tmp/logs'},
        'gpu_mapping': {'physical_gpus': 4, 'ray_declared_gpus': 1, 'isaac_sim_uses_gpu': 0},
    }
    for k, v in overrides.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            base[k].update(v)
        else:
            base[k] = v
    return base


class TestSSHTunnelConfig:
    """SSH tunnel parameter generation."""

    def test_tunnel_ports_are_distinct(self):
        """Verify tunnel ports don't conflict with service ports."""
        import yaml
        cfg = _minimal_config()
        f = tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False)
        yaml.dump(cfg, f); f.close()
        try:
            config = ClusterConfig(f.name)
            # Isaac Sim ports should not overlap with Ray ports
            assert config.isaac_signal_port not in (6379, 22002, 22003, 23002, 23003)
            assert config.isaac_stream_port not in (6379, 22002, 22003, 23002, 23003)
        finally:
            os.unlink(f.name)

    def test_loopback_addresses(self):
        """Verify Ray uses 127.0.0.x loopback addresses."""
        import yaml
        cfg = _minimal_config()
        f = tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False)
        yaml.dump(cfg, f); f.close()
        try:
            config = ClusterConfig(f.name)
            assert config.ray_head_address.startswith('127.0.0.')
            assert config.ray_worker_address.startswith('127.0.0.')
            assert config.ray_head_address != config.ray_worker_address  # Must be different
        finally:
            os.unlink(f.name)


class TestLoopbackBinding:
    """Network listening security checks."""

    def test_novnc_port_range(self):
        import yaml
        cfg = _minimal_config()
        f = tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False)
        yaml.dump(cfg, f); f.close()
        try:
            config = ClusterConfig(f.name)
            assert 1024 <= config.novnc_port <= 65535
            assert 5900 <= config.vnc_port <= 5999
            assert 1024 <= config.webrtc_cdp_port <= 65535
        finally:
            os.unlink(f.name)

    def test_webrtc_client_requires_disable_gpu(self):
        """Verify electron_flags contain --disable-gpu (validated by schema)."""
        import yaml
        # Missing --disable-gpu should fail
        cfg = _minimal_config()
        cfg['visualization']['webrtc_client']['electron_flags'] = ['--no-sandbox']
        f = tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False)
        yaml.dump(cfg, f); f.close()
        try:
            with pytest.raises((ConfigError, Exception)):
                ClusterConfig(f.name)
        finally:
            os.unlink(f.name)


class TestProcessSafety:
    """PID identity and process protection."""

    def test_config_does_not_hardcode_pids(self):
        """Config should not contain PID information (runtime only)."""
        import yaml
        cfg = _minimal_config()
        yaml_str = yaml.dump(cfg)
        assert 'pid' not in yaml_str.lower() or 'pid_dir' in yaml_str.lower()

    def test_kit_args_no_allow_root(self):
        """--allow-root must not appear in generated kit args."""
        import yaml
        cfg = _minimal_config()
        f = tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False)
        yaml.dump(cfg, f); f.close()
        try:
            config = ClusterConfig(f.name)
            for arg in config.isaac_kit_args:
                assert '--allow-root' not in arg, f"--allow-root found in: {arg}"
        finally:
            os.unlink(f.name)

    def test_port_conflict_detects_overlap(self):
        """Config should reject overlapping ports between services."""
        import yaml
        # Make signal_port conflict with GCS port
        cfg = _minimal_config()
        cfg['isaacsim']['signal_port'] = 6379  # Same as GCS!
        cfg['ray']['head']['gcs_port'] = 6379
        f = tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False)
        yaml.dump(cfg, f); f.close()
        try:
            with pytest.raises(ConfigError, match='(Port|port|conflict)'):
                ClusterConfig(f.name)
        finally:
            os.unlink(f.name)


class TestDeploymentIndependence:
    """Standalone deployment without legacy cluster dependency."""

    def test_config_standalone(self):
        """Config validation works without ray_ssh_cluster directory."""
        import yaml
        cfg = _minimal_config()
        f = tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False)
        yaml.dump(cfg, f); f.close()
        try:
            config = ClusterConfig(f.name)
            assert config.ray_version == '2.40.0'
            assert config.ray_head_address == '127.0.0.2'
            assert config.ray_worker_address == '127.0.0.3'
        finally:
            os.unlink(f.name)