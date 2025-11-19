"""
Sol Standard Library - System Operations Module
Provides system information and environment variable functions.
"""
import os
import subprocess
from typing import Any, Dict, Optional, Union
from toolz import curry
from .result import Result, ok, err


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
def getenv(key: str, default: Optional[str] = None) -> Union[str, Result]:
    """
    Get environment variable value.

    Args:
        key: Environment variable name
        default: Default value if not found (default: None, returns Result.Err)

    Returns:
        Environment variable value if found, or Result.Err if not found and no default

    Examples:
        >>> getenv("HOME")
        '/home/user'
        >>> getenv("MISSING_VAR")
        Err('Environment variable MISSING_VAR not found')
        >>> getenv("MISSING_VAR", "default_value")
        'default_value'
    """
    value = os.getenv(key)
    if value is not None:
        return value
    elif default is not None:
        return default
    else:
        return err(f"Environment variable {key} not found")


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


def sh(command: str) -> Result:
    """
    Execute a shell command and return a Result.

    Args:
        command: Shell command to execute

    Returns:
        Result with dict containing stdout, stderr, and exit_code if successful,
        or error message if failed

    Examples:
        >>> sh("echo hello")
        Ok({'stdout': 'hello\\n', 'stderr': '', 'exit_code': 0})
        >>> sh("false")
        Err({'stdout': '', 'stderr': '', 'exit_code': 1})
    """
    try:
        result = subprocess.run(
            command,
            shell=True,
            capture_output=True,
            text=True,
            timeout=300  # 5 minute timeout
        )

        output_dict = {
            'stdout': result.stdout,
            'stderr': result.stderr,
            'exit_code': result.returncode
        }

        # Success if exit code is 0
        if result.returncode == 0:
            return ok(output_dict)
        else:
            return err(f"Command failed with exit code {result.returncode}")
    except subprocess.TimeoutExpired:
        return err("Command timed out after 5 minutes")
    except Exception as e:
        return err(f"Failed to execute command: {str(e)}")


def exit_cmd(code: int = 0) -> None:
    """
    Exit the program with given exit code.

    Args:
        code: Exit code (default: 0 for success)

    Examples:
        >>> exit_cmd(0)
        >>> exit_cmd(1)
    """
    import sys
    sys.exit(code)


# Export all functions
__all__ = [
    'cpu_count', 'memory_info', 'disk_usage',
    'getenv', 'setenv', 'listenv', 'sh', 'exit_cmd'
]
