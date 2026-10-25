#!/usr/bin/env python3
"""config_bridge.py - Output validated config as JSON for PowerShell consumption.
Must work from ANY working directory without installing the package.
Usage:
  python3 config_bridge.py [profile_name] [--config PATH] [--key path.to.key]
"""
import json
import sys
import os
from pathlib import Path


def find_project_root() -> Path:
    """Find project root from this script's location.
    This file is at <root>/linux/common/config_bridge.py"""
    return Path(__file__).resolve().parent.parent.parent


def setup_import_path(project_root: Path):
    """Add src/ to sys.path so 'ray_isaac_deploy' is importable."""
    src_dir = project_root / "src"
    if str(src_dir) not in sys.path:
        sys.path.insert(0, str(src_dir))


def main():
    project_root = find_project_root()
    setup_import_path(project_root)

    try:
        from ray_isaac_deploy.config import ClusterConfig, ConfigError
    except ImportError as e:
        print(json.dumps({
            "valid": False,
            "error": f"Cannot import ray_isaac_deploy from {project_root}/src/: {e}",
        }))
        sys.exit(1)

    # Parse arguments
    profile_name = "verified-20261025"
    config_path = None
    key = None
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        if args[i] == '--config' and i + 1 < len(args):
            config_path = args[i + 1]; i += 2
        elif args[i] == '--key' and i + 1 < len(args):
            key = args[i + 1]; i += 2
        elif not args[i].startswith('--'):
            profile_name = args[i]; i += 1
        else:
            i += 1

    # Build config path
    if config_path:
        config_file = Path(config_path)
    else:
        config_file = project_root / "profiles" / f"{profile_name}.yaml"

    if not config_file.exists():
        print(json.dumps({
            "valid": False,
            "error": f"Config file not found: {config_file}",
        }))
        sys.exit(1)

    try:
        config = ClusterConfig(str(config_file))
    except ConfigError as e:
        print(json.dumps({"valid": False, "error": str(e)}))
        sys.exit(1)
    except Exception as e:
        print(json.dumps({"valid": False, "error": f"Config load failed: {e}"}))
        sys.exit(1)

    result = config.to_dict()
    result['valid'] = True

    if key:
        val = result
        for k in key.split('.'):
            if isinstance(val, dict):
                val = val.get(k)
            else:
                val = None
                break
        print(str(val) if val is not None else '')
    else:
        print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()