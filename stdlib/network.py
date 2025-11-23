"""
Sol Standard Library - Network Operations Module
Provides HTTP requests and network scanning functionality with progress support.
"""
import subprocess
import sys
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


def _download_with_progress(url: str, show_progress: bool = False) -> str:
    """
    Download with optional progress bar support.

    Args:
        url: URL to download from
        show_progress: Whether to show progress bar

    Returns:
        Downloaded content as string
    """
    requests = _import_requests()

    response = requests.get(url, stream=True, timeout=30)
    response.raise_for_status()

    # Get total size if available
    total_size = int(response.headers.get('content-length', 0))

    if show_progress and total_size > 0:
        # Import ProgressBar locally to avoid circular dependency
        from stdlib.conversion import ProgressBar

        progress_bar = ProgressBar(total=total_size, width=40, desc="Downloading")

        chunks = []
        downloaded = 0

        # Download in chunks
        chunk_size = 8192
        for chunk in response.iter_content(chunk_size=chunk_size):
            if chunk:
                chunks.append(chunk)
                downloaded += len(chunk)
                progress_bar.set_progress(downloaded)

        progress_bar.finish()

        # Decode content
        content = b''.join(chunks).decode('utf-8', errors='ignore')
        return content
    else:
        # For small files or when no content-length, just download directly
        if show_progress:
            # Show quick progress animation
            from stdlib.conversion import ProgressBar
            progress_bar = ProgressBar(total=10, desc="Downloading")
            for i in range(11):
                progress_bar.set_progress(i)
            progress_bar.finish()

        return response.text


@curry
def wget(url: str, with_progress: bool = False) -> str:
    """
    Download content from URL via HTTP GET.

    Args:
        url: URL to download from
        with_progress: Show progress bar (default: False)

    Returns:
        Response body as string or error message

    Examples:
        >>> wget("https://api.github.com/zen")
        "Design for failure."

        >>> wget("https://example.com/file.txt", True)
        Downloading: [========================================] 100%
        "file content..."

    Errors:
        - ConnectionError: Network unreachable
        - Timeout: Request took too long
        - HTTPError: Non-2xx status code
    """
    try:
        return _download_with_progress(url, show_progress=with_progress)
    except Exception as e:
        return f"Error downloading from {url}: {e}"


@curry
def get(url: str, with_progress: bool = False) -> str:
    """
    Make HTTP GET request (alias for wget).

    Args:
        url: URL to request
        with_progress: Show progress bar (default: False)

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
    return wget(url, with_progress)


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
