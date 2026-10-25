#!/usr/bin/env python3
"""config_bridge.py - Output validated config as JSON for PowerShell consumption.
Usage: python3 config_bridge.py [profile_name] [--key path.to.key]
"""
import json
import sys
import os

# Allow running from any directory
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    from ray_isaac_deploy.config import ClusterConfig, ConfigError, load_config
except ImportError:
    # Direct import when run from project root
    sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'src'))
    from ray_isaac_deploy.config import ClusterConfig, ConfigError, load_config


def main():
    profile = sys.argv[1] if len(sys.argv) > 1 else 'verified-20261025'
    key = None
    for i, arg in enumerate(sys.argv):
        if arg == '--key' and i + 1 < len(sys.argv):
            key = sys.argv[i + 1]
            break

    try:
        config = load_config(profile)
    except ConfigError as e:
        print(json.dumps({"error": str(e), "valid": False}))
        sys.exit(1)

    result = config.to_dict()
    result['valid'] = True

    if key:
        # Deep key lookup: 'hosts.a800.ssh_host'
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