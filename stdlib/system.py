"""
Sol Standard Library - System Operations Module
Provides system information and environment variable functions.
"""
import os
from typing import Any, Dict, Optional
from toolz import curry


def _import_psutil():
    """Lazy import psutil library."""
    try:
        import psutil
        return psutil
    except ImportError:
        raise ImportError(
            "psutil library not found. Install with: pip install psutil")


def cpu_count() -> int:
    """
    Get number of CPU cores.

    Returns:
        Number of logical CPU cores

    Examples:
        >>> cpu_count()
        8

    Notes:
        Returns logical cores (includes hyperthreading)
    """
    try:
        psutil = _import_psutil()
        count = psutil.cpu_count()
        return count if count is not None else 1
    except Exception:
        return os.cpu_count() or 1


def memory_info() -> Dict[str, Any]:
    """
    Get system memory information.

    Returns:
        Dictionary with memory statistics in bytes

    Examples:
        >>> memory_info()
        {
            'total': 17179869184,
            'available': 8589934592,
            'percent': 50.0,
            'used': 8589934592,
            'free': 8589934592
        }

    Errors:
        - ImportError: psutil not installed
        - OSError: Unable to get memory info
    """
    try:
        psutil = _import_psutil()
        mem = psutil.virtual_memory()
        return {
            'total': mem.total,
            'available': mem.available,
            'percent': mem.percent,
            'used': mem.used,
            'free': mem.free
        }
    except Exception as e:
        return {'error': str(e)}


def disk_usage(path: str = "/") -> Dict[str, Any]:
    """
    Get disk usage statistics for path.

    Args:
        path: Path to check disk usage (default: "/")

    Returns:
        Dictionary with disk usage in bytes and percentage

    Examples:
        >>> disk_usage("/")
        {
            'total': 500000000000,
            'used': 250000000000,
            'free': 250000000000,
            'percent': 50.0
        }

    Errors:
        - FileNotFoundError: Path doesn't exist
        - PermissionError: No access to path
    """
    try:
        psutil = _import_psutil()
        usage = psutil.disk_usage(path)
        return {
            'total': usage.total,
            'used': usage.used,
            'free': usage.free,
            'percent': (usage.used / usage.total) * 100
        }
    except Exception as e:
        return {'error': str(e)}


@curry
def getenv(key: str, default: Optional[str] = None) -> str:
    """
    Get environment variable value.

    Args:
        key: Environment variable name
        default: Default value if not found (default: "")

    Returns:
        Environment variable value or default

    Examples:
        >>> getenv("HOME")
        '/home/user'
        >>> getenv("MISSING_VAR", "default_value")
        'default_value'
    """
    return os.getenv(key, default or "")


@curry
def setenv(key: str, value: str) -> str:
    """
    Set environment variable.

    Args:
        key: Environment variable name
        value: Value to set

    Returns:
        Confirmation message

    Examples:
        >>> setenv("MY_VAR", "my_value")
        "Set MY_VAR=my_value"

    Notes:
        Changes only affect current process and children
    """
    os.environ[key] = value
    return f"Set {key}={value}"


def listenv() -> Dict[str, str]:
    """
    List all environment variables.

    Returns:
        Dictionary of all environment variables

    Examples:
        >>> listenv()
        {'HOME': '/home/user', 'PATH': '/usr/bin:...', ...}

    Notes:
        May contain sensitive information (API keys, passwords)
    """
    return dict(os.environ)


# Export all functions
__all__ = [
    'cpu_count', 'memory_info', 'disk_usage',
    'getenv', 'setenv', 'listenv'
]
