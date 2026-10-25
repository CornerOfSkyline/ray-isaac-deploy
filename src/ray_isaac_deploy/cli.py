"""ray-isaac-deploy CLI - Unified command-line interface."""
import argparse
import sys
import os
from pathlib import Path

from .config import ClusterConfig, ConfigError, load_config
from .diagnostics import Diagnostics


def cmd_status(config: ClusterConfig):
    """Print deployment status."""
    diag = Diagnostics(config)
    result = diag.run_full_diagnostics()

    print("\n=== Ray + Isaac Sim Status ===")
    print(f"Timestamp: {result['timestamp']}")

    # SSH
    ssh = result['ssh_connectivity']
    print(f"\nSSH: A800={'OK' if ssh['a800_reachable'] else 'OFFLINE'}  4090={'OK' if ssh['gpu4090_reachable'] else 'OFFLINE'}")

    # Ray
    ray = result['ray_cluster']
    print(f"\nRay: {ray.get('alive_nodes', 0)} nodes alive, {ray.get('total_gpu', 0)} GPUs")
    for n in ray.get('nodes', []):
        print(f"  {n['name']}: GPU={n['gpu']}")

    # GPU
    gpu = result['gpu']
    print(f"\nGPU: {gpu.get('count', 0)} detected")
    for g in gpu.get('gpus', []):
        print(f"  GPU{g['index']}: {g['memory_used_mb']}/{g['memory_total_mb']}MB  {g['utilization_pct']}%")

    # Visualization layers
    viz = result['visualization']
    for layer, checks in viz.items():
        for name, value in checks.items():
            status = 'PASS' if value else 'FAIL'
            print(f"  {layer}: {name} = {status}")


def cmd_verify(config: ClusterConfig):
    """Run full verification."""
    diag = Diagnostics(config)
    ready, details = diag.visualization_ready()
    print(f"\nVisualization Ready: {ready}")
    print(f"Details: {details}")
    sys.exit(0 if ready else 1)


def cmd_doctor(config: ClusterConfig):
    """Run comprehensive diagnostics."""
    cmd_status(config)
    cmd_verify(config)


def cmd_validate(profile_path: str):
    """Validate a configuration profile."""
    try:
        config = ClusterConfig(profile_path)
        print(f"Configuration valid: {profile_path}")
        print(f"  Ray version: {config.ray_version}")
        print(f"  Isaac Sim: {config.isaac_public_ip}:{config.isaac_signal_port}")
        print(f"  VNC: {config.vnc_display} port {config.vnc_port}")
        print(f"  noVNC: port {config.novnc_port}")
        sys.exit(0)
    except ConfigError as e:
        print(f"Configuration INVALID: {e}")
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description='Ray + Isaac Sim Deployment Toolkit',
        prog='ray-isaac-deploy'
    )
    parser.add_argument('action', nargs='?', default='status',
                        choices=['status', 'verify', 'doctor', 'validate', 'configure'])
    parser.add_argument('--profile', '-p', default='verified-20261025',
                        help='Configuration profile name')
    parser.add_argument('--config', '-c', help='Path to config file')
    args = parser.parse_args()

    if args.action == 'validate':
        profile_path = args.config or os.path.join(
            Path(__file__).parent.parent.parent, 'profiles', f'{args.profile}.yaml')
        cmd_validate(profile_path)
        return

    try:
        config = load_config(args.profile)
    except ConfigError as e:
        print(f"Config error: {e}", file=sys.stderr)
        sys.exit(1)

    actions = {
        'status': cmd_status,
        'verify': cmd_verify,
        'doctor': cmd_doctor,
    }
    actions[args.action](config)


if __name__ == '__main__':
    main()