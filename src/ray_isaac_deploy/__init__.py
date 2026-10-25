"""ray-isaac-deploy: Standardized deployment toolkit for Ray 2.40.0 + Isaac Sim 6.2.0.

Architecture:
  Windows Controller -> A800 (Ray Head) + 4090 (Ray Worker + Isaac Sim)
  Visualization: Isaac Sim -> local WebRTC -> Xvnc -> noVNC -> SSH -> Browser
"""

__version__ = "1.1.0"

from .config import ClusterConfig, ConfigError, load_config
from .diagnostics import Diagnostics
from .process_registry import ProcessRegistry
from .visualization import VisualizationStack
from .ssh import TunnelManager
from .gpu import get_gpu_info, check_nvenc, check_vulkan
from .cli import main as cli_main