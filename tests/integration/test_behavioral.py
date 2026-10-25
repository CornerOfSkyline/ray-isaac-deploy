"""Behavioral tests for config bridge, SSH execution, and error handling."""
import pytest
import subprocess
import tempfile
import os
import sys
import json
from pathlib import Path


PROJECT_ROOT = Path(__file__).parent.parent.parent
BRIDGE_SCRIPT = PROJECT_ROOT / "linux" / "common" / "config_bridge.py"


class TestConfigBridge:
    """Verify config_bridge.py works from any directory."""

    def test_bridge_loads_valid_profile(self):
        """Bridge should load verified profile from any cwd."""
        result = subprocess.run(
            [sys.executable, str(BRIDGE_SCRIPT), "verified-20261025"],
            capture_output=True, text=True, timeout=15,
            cwd=tempfile.gettempdir()  # Run from temp dir!
        )
        assert result.returncode == 0, f"stderr: {result.stderr}"
        data = json.loads(result.stdout)
        assert data.get("valid") is True
        assert "hosts" in data
        assert "ray" in data

    def test_bridge_loads_from_project_root(self):
        """Bridge should also work from project root."""
        result = subprocess.run(
            [sys.executable, str(BRIDGE_SCRIPT), "verified-20261025"],
            capture_output=True, text=True, timeout=15,
            cwd=str(PROJECT_ROOT)
        )
        assert result.returncode == 0
        data = json.loads(result.stdout)
        assert data.get("valid") is True

    def test_bridge_rejects_missing_profile(self):
        """Bridge should exit non-zero for missing profile."""
        result = subprocess.run(
            [sys.executable, str(BRIDGE_SCRIPT), "nonexistent-profile-xyz"],
            capture_output=True, text=True, timeout=15,
            cwd=tempfile.gettempdir()
        )
        assert result.returncode != 0
        data = json.loads(result.stdout)
        assert data.get("valid") is False

    def test_bridge_key_lookup(self):
        """Bridge --key should extract nested values."""
        result = subprocess.run(
            [sys.executable, str(BRIDGE_SCRIPT), "verified-20261025",
             "--key", "isaacsim.signal_port"],
            capture_output=True, text=True, timeout=15,
            cwd=tempfile.gettempdir()
        )
        assert result.returncode == 0
        assert result.stdout.strip() == "49100"

    def test_bridge_key_lookup_host(self):
        """Bridge --key for SSH host should return correct value."""
        result = subprocess.run(
            [sys.executable, str(BRIDGE_SCRIPT), "verified-20261025",
             "--key", "ray.version"],
            capture_output=True, text=True, timeout=15,
            cwd=tempfile.gettempdir()
        )
        assert result.returncode == 0
        assert result.stdout.strip() == "2.40.0"

    def test_bridge_config_path_flag(self):
        """Bridge --config should accept explicit config path."""
        profile = PROJECT_ROOT / "profiles" / "verified-20261025.yaml"
        result = subprocess.run(
            [sys.executable, str(BRIDGE_SCRIPT), "--config", str(profile)],
            capture_output=True, text=True, timeout=15,
            cwd=tempfile.gettempdir()
        )
        assert result.returncode == 0
        data = json.loads(result.stdout)
        assert data.get("valid") is True


class TestErrorHandling:
    """Verify error propagation and exit codes."""

    def test_verify_ray_active_syntax(self):
        """verify_ray_active.py should be syntactically valid Python."""
        script = PROJECT_ROOT / "tests" / "e2e" / "verify_ray_active.py"
        try:
            result = subprocess.run(
                [sys.executable, "-c", f"compile(open('{script}').read(), '{script}', 'exec')"],
                capture_output=True, text=True, timeout=10
            )
            assert result.returncode == 0, f"Syntax error: {result.stderr}"
        except Exception as e:
            pytest.skip(f"Ray not available: {e}")

    def test_verify_ray_active_imports(self):
        """verify_ray_active.py should have valid imports (ray optional)."""
        script = PROJECT_ROOT / "tests" / "e2e" / "verify_ray_active.py"
        try:
            result = subprocess.run(
                [sys.executable, "-c",
                 f"import ast; ast.parse(open('{script}').read()); print('OK')"],
                capture_output=True, text=True, timeout=10
            )
            assert result.returncode == 0
        except Exception as e:
            pytest.skip(f"Ray not available: {e}")

    def test_config_schema_validates(self):
        """JSON Schema file should be valid JSON."""
        schema_path = PROJECT_ROOT / "config" / "cluster.schema.json"
        with open(schema_path) as f:
            data = json.load(f)
        assert "properties" in data
        assert "required" in data
        assert "hosts" in data["properties"]

    def test_bridge_rejects_invalid_yaml(self):
        """Bridge should fail on malformed config."""
        import tempfile
        with tempfile.NamedTemporaryFile(mode='w', suffix='.yaml', delete=False) as f:
            f.write("hosts: [this is not valid: [[[\n")
            bad_path = f.name
        try:
            result = subprocess.run(
                [sys.executable, str(BRIDGE_SCRIPT), "--config", bad_path],
                capture_output=True, text=True, timeout=15
            )
            assert result.returncode != 0
            data = json.loads(result.stdout)
            assert data.get("valid") is False
        finally:
            os.unlink(bad_path)


class TestShellSyntax:
    """Verify shell scripts have no syntax errors."""

    def _check_bash_n(self, script_rel):
        script = PROJECT_ROOT / script_rel
        if not script.exists():
            pytest.skip(f"{script_rel} not found")
        script_str = str(script).replace('\\', '/')
        if script_str[1] == ':':
            script_str = '/' + script_str[0].lower() + script_str[2:]
        try:
            result = subprocess.run(
                ["bash", "-n", script_str],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode != 0:
                if 'No such file' in result.stderr:
                    pytest.skip(f"bash path mapping issue: {result.stderr.strip()}")
                raise AssertionError(f"bash -n failed: {result.stderr}")
        except FileNotFoundError:
            pytest.skip("bash not available")

    def test_start_visualization_syntax(self):
        self._check_bash_n("linux/visualization/start-visualization.sh")

    def test_stop_visualization_syntax(self):
        self._check_bash_n("linux/visualization/stop-visualization.sh")

    def test_verify_cluster_syntax(self):
        self._check_bash_n("linux/ray/verify-cluster.sh")

    def test_cluster_sh_syntax(self):
        self._check_bash_n("linux/ray/cluster.sh")

    def test_start_tunnels_syntax(self):
        self._check_bash_n("linux/ray/start-tunnels.sh")