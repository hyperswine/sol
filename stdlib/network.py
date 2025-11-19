"""
Sol Standard Library - Network Operations Module
Provides HTTP requests and network scanning functionality.
"""
import subprocess
from typing import Any, Dict, Optional
from toolz import curry


def _import_requests():
    """Lazy import requests library."""
    try:
        import requests
        return requests
    except ImportError:
        raise ImportError(
            "requests library not found. Install with: pip install requests")


def _import_nmap():
    """Lazy import python-nmap library."""
    try:
        import nmap
        return nmap
    except ImportError:
        raise ImportError(
            "python-nmap library not found. Install with: pip install python-nmap")


@curry
def wget(url: str) -> str:
    """
    Download content from URL via HTTP GET.

    Args:
        url: URL to download from

    Returns:
        Response body as string or error message

    Examples:
        >>> wget("https://api.github.com/zen")
        "Design for failure."

    Errors:
        - ConnectionError: Network unreachable
        - Timeout: Request took too long
        - HTTPError: Non-2xx status code
    """
    try:
        requests = _import_requests()
        response = requests.get(url, timeout=30)
        response.raise_for_status()
        return response.text
    except Exception as e:
        return f"Error downloading from {url}: {e}"


@curry
def get(url: str) -> str:
    """
    Make HTTP GET request (alias for wget).

    Args:
        url: URL to request

    Returns:
        Response body as string or error message

    Examples:
        >>> get("https://httpbin.org/get")
        '{"args": {}, "headers": {...}}'

    Errors:
        - ConnectionError: Network unreachable
        - Timeout: Request took too long
        - HTTPError: Non-2xx status code
    """
    return wget(url)


@curry
def post(url: str, data: Optional[Dict[str, Any]] = None) -> str:
    """
    Make HTTP POST request with JSON data.

    Args:
        url: URL to post to
        data: Dictionary to send as JSON body (default: {})

    Returns:
        Response body as string or error message

    Examples:
        >>> post("https://httpbin.org/post", {"key": "value"})
        '{"json": {"key": "value"}, ...}'

    Errors:
        - ConnectionError: Network unreachable
        - Timeout: Request took too long
        - HTTPError: Non-2xx status code
    """
    try:
        requests = _import_requests()
        response = requests.post(url, json=data or {}, timeout=30)
        response.raise_for_status()
        return response.text
    except Exception as e:
        return f"Error making POST request to {url}: {e}"


@curry
def ping(host: str) -> str:
    """
    Ping host using system ping command (4 packets).

    Args:
        host: Hostname or IP address to ping

    Returns:
        Ping output as string or error message

    Examples:
        >>> ping("8.8.8.8")
        'PING 8.8.8.8 (8.8.8.8): 56 data bytes\\n64 bytes from 8.8.8.8: ...'

    Errors:
        - TimeoutError: Host unreachable within timeout
        - CalledProcessError: Ping command failed
    """
    try:
        result = subprocess.run(
            ['ping', '-c', '4', host],
            capture_output=True,
            text=True,
            timeout=10
        )
        if result.returncode == 0:
            return result.stdout
        else:
            return f"Ping failed: {result.stderr}"
    except Exception as e:
        return f"Error pinging {host}: {e}"


@curry
def nmap_scan(target: str) -> str:
    """
    Scan target for open ports using nmap (ports 22-443).

    Args:
        target: IP address or hostname to scan

    Returns:
        Formatted scan results or error message

    Examples:
        >>> nmap_scan("192.168.1.1")
        'Host: 192.168.1.1 (router.local)\\nState: up\\nPort 22/tcp: open\\nPort 80/tcp: open'

    Errors:
        - ImportError: python-nmap not installed
        - PermissionError: Requires root/admin for some scans
        - OSError: nmap binary not found

    Notes:
        Requires nmap to be installed on the system
    """
    try:
        nmap = _import_nmap()
        nm = nmap.PortScanner()
        result = nm.scan(target, '22-443')

        def format_host_info(host):
            """Format information for a single host."""
            host_lines = [
                f"Host: {host} ({nm[host].hostname()})",
                f"State: {nm[host].state()}"
            ]

            port_lines = [
                f"Port {port}/{protocol}: {nm[host][protocol][port]['state']}"
                for protocol in nm[host].all_protocols()
                for port in nm[host][protocol].keys()
            ]

            return host_lines + port_lines

        # Generate output using functional composition
        output = [
            line
            for host in nm.all_hosts()
            for line in format_host_info(host)
        ]

        return "\n".join(output) if output else "No hosts found"
    except Exception as e:
        return f"Error scanning {target}: {e}"


# Export all functions
__all__ = ['wget', 'get', 'post', 'ping', 'nmap_scan']
