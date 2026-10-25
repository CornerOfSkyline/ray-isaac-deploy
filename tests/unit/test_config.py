"""Unit tests for ray-isaac-deploy configuration."""
import pytest
import json
import tempfile
import os
from pathlib import Path

# Add src to path
import sys
sys.path.insert(0, str(Path(__file__).parent.parent.parent / 'src'))

from ray_isaac_deploy.config import ClusterConfig, ConfigError


class TestConfigValidation:
    """Test configuration loading and validation."""

    def _write_config(self, data: dict) -> str:
        import yaml
        f = tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False)
        yaml.dump(data, f)
        f.close()
        return f.name

    def test_valid_minimal_config(self):
        cfg = self._write_config({
            'hosts': {
                'windows': {'role': 'controller'},
                'a800': {'role': 'ray_head', 'ssh_host': '1.2.3.4', 'ssh_port': 22, 'ssh_user': 'test'},
                'gpu4090': {'role': 'ray_worker_and_isaac_sim', 'ssh_host': '5.6.7.8', 'ssh_port': 22, 'ssh_user': 'test'},
            },
            'ray': {
                'version': '2.40.0',
                'head': {'address': '127.0.0.2'},
                'worker': {'address': '127.0.0.3'},
            },
            'isaacsim': {
                'install_path': '/tmp/isaacsim',
                'signal_port': 49100,
                'stream_port': 47998,
                'public_ip': '192.168.0.1',
            },
            'visualization': {
                'vnc': {'binary': '/usr/bin/Xvnc', 'display': ':1', 'port': 5901, 'geometry': '1920x1080'},
                'novnc': {'path': '/tmp/novnc', 'websockify': '/usr/bin/websockify', 'port': 6006},
                'webrtc_client': {'path': '/tmp/client', 'cdp_port': 9222, 'electron_flags': ['--disable-gpu']},
            }
        })
        try:
            config = ClusterConfig(cfg)
            assert config.ray_version == '2.40.0'
            assert config.isaac_signal_port == 49100
            assert config.vnc_port == 5901
            assert config.novnc_port == 6006
            assert config.webrtc_cdp_port == 9222
        finally:
            os.unlink(cfg)

    def test_missing_required_section(self):
        cfg = self._write_config({
            'hosts': {'windows': {'role': 'controller'}},
            # Missing ray, isaacsim, visualization
        })
        try:
            with pytest.raises(ConfigError, match='Missing required'):
                ClusterConfig(cfg)
        finally:
            os.unlink(cfg)

    def test_invalid_ray_version(self):
        cfg = self._write_config({
            'hosts': {
                'windows': {'role': 'controller'},
                'a800': {'role': 'ray_head', 'ssh_host': '1.2.3.4', 'ssh_port': 22, 'ssh_user': 'test'},
                'gpu4090': {'role': 'ray_worker_and_isaac_sim', 'ssh_host': '5.6.7.8', 'ssh_port': 22, 'ssh_user': 'test'},
            },
            'ray': {
                'version': '2.99.0',  # Not 2.40.0
                'head': {'address': '127.0.0.2'},
                'worker': {'address': '127.0.0.3'},
            },
            'isaacsim': {'install_path': '/tmp', 'signal_port': 49100, 'stream_port': 47998, 'public_ip': '1.1.1.1'},
            'visualization': {
                'vnc': {'binary': '/tmp/v', 'display': ':1', 'port': 5901, 'geometry': '1920x1080'},
                'novnc': {'path': '/tmp/n', 'websockify': '/tmp/w', 'port': 6006},
                'webrtc_client': {'path': '/tmp/c', 'cdp_port': 9222, 'electron_flags': ['--disable-gpu']},
            }
        })
        try:
            with pytest.raises((ConfigError, Exception)):
                ClusterConfig(cfg)
        finally:
            os.unlink(cfg)

    def test_port_conflict_detection(self):
        cfg = self._write_config({
            'hosts': {
                'windows': {'role': 'controller'},
                'a800': {'role': 'ray_head', 'ssh_host': '1.2.3.4', 'ssh_port': 22, 'ssh_user': 'test'},
                'gpu4090': {'role': 'ray_worker_and_isaac_sim', 'ssh_host': '5.6.7.8', 'ssh_port': 22, 'ssh_user': 'test'},
            },
            'ray': {
                'version': '2.40.0',
                'head': {'address': '127.0.0.2', 'gcs_port': 49100},  # Same as signal_port!
                'worker': {'address': '127.0.0.3'},
            },
            'isaacsim': {
                'install_path': '/tmp/is',
                'signal_port': 49100,  # Conflict with gcs_port
                'stream_port': 47998,
                'public_ip': '1.1.1.1',
            },
            'visualization': {
                'vnc': {'binary': '/tmp/v', 'display': ':1', 'port': 5901, 'geometry': '1920x1080'},
                'novnc': {'path': '/tmp/n', 'websockify': '/tmp/w', 'port': 6006},
                'webrtc_client': {'path': '/tmp/c', 'cdp_port': 9222, 'electron_flags': ['--disable-gpu']},
            }
        })
        try:
            with pytest.raises(ConfigError, match='(Port|conflict)'):
                ClusterConfig(cfg)
        finally:
            os.unlink(cfg)

    def test_missing_electron_gpu_flag(self):
        cfg = self._write_config({
            'hosts': {
                'windows': {'role': 'controller'},
                'a800': {'role': 'ray_head', 'ssh_host': '1.2.3.4', 'ssh_port': 22, 'ssh_user': 'test'},
                'gpu4090': {'role': 'ray_worker_and_isaac_sim', 'ssh_host': '5.6.7.8', 'ssh_port': 22, 'ssh_user': 'test'},
            },
            'ray': {
                'version': '2.40.0',
                'head': {'address': '127.0.0.2'},
                'worker': {'address': '127.0.0.3'},
            },
            'isaacsim': {'install_path': '/tmp', 'signal_port': 49100, 'stream_port': 47998, 'public_ip': '1.1.1.1'},
            'visualization': {
                'vnc': {'binary': '/tmp/v', 'display': ':1', 'port': 5901, 'geometry': '1920x1080'},
                'novnc': {'path': '/tmp/n', 'websockify': '/tmp/w', 'port': 6006},
                'webrtc_client': {
                    'path': '/tmp/c', 'cdp_port': 9222,
                    'electron_flags': ['--no-sandbox']  # Missing --disable-gpu!
                },
            }
        })
        try:
            with pytest.raises((ConfigError, Exception)):
                ClusterConfig(cfg)
        finally:
            os.unlink(cfg)

    def test_kit_args_excludes_allow_root(self):
        """Verify --allow-root is NOT in generated kit args (added at execution)."""
        cfg = self._write_config({
            'hosts': {
                'windows': {'role': 'controller'},
                'a800': {'role': 'ray_head', 'ssh_host': '1.2.3.4', 'ssh_port': 22, 'ssh_user': 'test'},
                'gpu4090': {'role': 'ray_worker_and_isaac_sim', 'ssh_host': '5.6.7.8', 'ssh_port': 22, 'ssh_user': 'test'},
            },
            'ray': {
                'version': '2.40.0',
                'head': {'address': '127.0.0.2'},
                'worker': {'address': '127.0.0.3'},
            },
            'isaacsim': {'install_path': '/tmp', 'signal_port': 49100, 'stream_port': 47998, 'public_ip': '1.1.1.1'},
            'visualization': {
                'vnc': {'binary': '/tmp/v', 'display': ':1', 'port': 5901, 'geometry': '1920x1080'},
                'novnc': {'path': '/tmp/n', 'websockify': '/tmp/w', 'port': 6006},
                'webrtc_client': {'path': '/tmp/c', 'cdp_port': 9222, 'electron_flags': ['--disable-gpu']},
            }
        })
        try:
            config = ClusterConfig(cfg)
            args = config.isaac_kit_args
            assert '--allow-root' not in args, '--allow-root should NOT be in kit args'
            assert any('signalPort=49100' in a for a in args)
            assert any('streamPort=47998' in a for a in args)
        finally:
            os.unlink(cfg)

    def test_ssh_strings(self):
        cfg = self._write_config({
            'hosts': {
                'windows': {'role': 'controller'},
                'a800': {'role': 'ray_head', 'ssh_host': '10.0.0.1', 'ssh_port': 2222, 'ssh_user': 'admin'},
                'gpu4090': {'role': 'ray_worker_and_isaac_sim', 'ssh_host': '10.0.0.2', 'ssh_port': 3333, 'ssh_user': 'ops'},
            },
            'ray': {
                'version': '2.40.0',
                'head': {'address': '127.0.0.2'},
                'worker': {'address': '127.0.0.3'},
            },
            'isaacsim': {'install_path': '/tmp', 'signal_port': 49100, 'stream_port': 47998, 'public_ip': '1.1.1.1'},
            'visualization': {
                'vnc': {'binary': '/tmp/v', 'display': ':1', 'port': 5901, 'geometry': '1920x1080'},
                'novnc': {'path': '/tmp/n', 'websockify': '/tmp/w', 'port': 6006},
                'webrtc_client': {'path': '/tmp/c', 'cdp_port': 9222, 'electron_flags': ['--disable-gpu']},
            }
        })
        try:
            config = ClusterConfig(cfg)
            assert '10.0.0.1' in config.a800_ssh
            assert '2222' in config.a800_ssh
            assert '10.0.0.2' in config.gpu4090_ssh
            assert '3333' in config.gpu4090_ssh
        finally:
            os.unlink(cfg)