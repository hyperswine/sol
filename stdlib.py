"""
Sol Standard Library - Functional implementation with proper Python integrations
"""
import os
import sys
import hashlib
import json
import csv
from pathlib import Path
from typing import Any, Dict, List, Union, Callable, Optional
from functools import partial, reduce
from toolz import pipe, curry, compose

# Lazy imports - import heavy dependencies only when needed
def _import_requests():
    try:
        import requests
        return requests
    except ImportError:
        raise ImportError("requests library not found. Install with: pip install requests")

def _import_gitpython():
    try:
        import git
        return git
    except ImportError:
        raise ImportError("GitPython library not found. Install with: pip install GitPython")

def _import_nmap():
    try:
        import nmap
        return nmap
    except ImportError:
        raise ImportError("python-nmap library not found. Install with: pip install python-nmap")

def _import_psutil():
    try:
        import psutil
        return psutil
    except ImportError:
        raise ImportError("psutil library not found. Install with: pip install psutil")


# Core filesystem operations
@curry
def ls(path: Optional[str] = None) -> Union[List[str], str]:
    """List directory contents using pathlib"""
    target_path = Path(path or os.getcwd())
    try:
        return [item.name for item in target_path.iterdir()]
    except FileNotFoundError:
        return f"Error: Directory '{target_path}' not found"
    except PermissionError:
        return f"Error: Permission denied accessing '{target_path}'"

def pwd() -> str:
    """Get current working directory"""
    return str(Path.cwd())

@curry
def mkdir(path: str) -> str:
    """Create directory using pathlib"""
    try:
        Path(path).mkdir(parents=True, exist_ok=True)
        return f"Directory '{path}' created"
    except Exception as e:
        return f"Error creating directory: {e}"

@curry
def rm(path: str) -> str:
    """Remove file or directory using pathlib"""
    try:
        target_path = Path(path)
        if target_path.is_file():
            target_path.unlink()
            return f"File '{path}' removed"
        elif target_path.is_dir():
            target_path.rmdir()
            return f"Directory '{path}' removed"
        else:
            return f"Error: '{path}' not found"
    except Exception as e:
        return f"Error removing '{path}': {e}"

@curry
def echo(text: Any) -> str:
    """Print text to stdout"""
    return str(text)

@curry
def read_file(path: str) -> str:
    """Read file contents using pathlib"""
    try:
        return Path(path).read_text(encoding='utf-8')
    except Exception as e:
        return f"Error reading file: {e}"

@curry
def write_file(path: str, content: str) -> str:
    """Write content to file using pathlib"""
    try:
        Path(path).write_text(content, encoding='utf-8')
        return f"Content written to '{path}'"
    except Exception as e:
        return f"Error writing file: {e}"

@curry
def cp(src: str, dst: str) -> str:
    """Copy file using pathlib"""
    try:
        import shutil
        shutil.copy2(src, dst)
        return f"Copied '{src}' to '{dst}'"
    except Exception as e:
        return f"Error copying file: {e}"

@curry
def mv(src: str, dst: str) -> str:
    """Move file using pathlib"""
    try:
        Path(src).rename(dst)
        return f"Moved '{src}' to '{dst}'"
    except Exception as e:
        return f"Error moving file: {e}"

@curry
def touch(path: str) -> str:
    """Create empty file using pathlib"""
    try:
        Path(path).touch()
        return f"Created '{path}'"
    except Exception as e:
        return f"Error creating file: {e}"

@curry
def find(pattern: str, path: str = ".") -> List[str]:
    """Find files matching pattern using pathlib"""
    try:
        target_path = Path(path)
        return [str(p) for p in target_path.rglob(pattern)]
    except Exception as e:
        return [f"Error finding files: {e}"]

# Web operations using requests
@curry
def wget(url: str) -> str:
    """Download content from URL using requests"""
    try:
        requests = _import_requests()
        response = requests.get(url, timeout=30)
        response.raise_for_status()
        return response.text
    except Exception as e:
        return f"Error downloading from {url}: {e}"

@curry
def get(url: str) -> str:
    """Make HTTP GET request using requests"""
    return wget(url)  # This will resolve to the curried function call

@curry
def post(url: str, data: Optional[Dict[str, Any]] = None) -> str:
    """Make HTTP POST request using requests"""
    try:
        requests = _import_requests()
        response = requests.post(url, json=data or {}, timeout=30)
        response.raise_for_status()
        return response.text
    except Exception as e:
        return f"Error making POST request to {url}: {e}"

# Hash functions using hashlib
@curry
def md5(text: Any) -> str:
    """Calculate MD5 hash using hashlib"""
    return hashlib.md5(str(text).encode()).hexdigest()

@curry
def sha256(text: Any) -> str:
    """Calculate SHA256 hash using hashlib"""
    return hashlib.sha256(str(text).encode()).hexdigest()

# Git operations using GitPython
@curry
def git_status(repo_path: str = ".") -> str:
    """Get git status using GitPython"""
    try:
        git = _import_gitpython()
        repo = git.Repo(repo_path)
        status_output = []
        
        # Get status
        if repo.is_dirty():
            status_output.append("Modified files:")
            for item in repo.index.diff(None):
                status_output.append(f"  M {item.a_path}")
        
        # Get untracked files
        untracked = repo.untracked_files
        if untracked:
            status_output.append("Untracked files:")
            for file in untracked:
                status_output.append(f"  ?? {file}")
        
        if not status_output:
            status_output.append("Working directory clean")
        
        return "\n".join(status_output)
    except Exception as e:
        return f"Error getting git status: {e}"

@curry
def git_add(file_path: str, repo_path: str = ".") -> str:
    """Add file to git using GitPython"""
    try:
        git = _import_gitpython()
        repo = git.Repo(repo_path)
        repo.index.add([file_path])
        return f"Added '{file_path}' to git index"
    except Exception as e:
        return f"Error adding file to git: {e}"

@curry
def git_commit(message: str, repo_path: str = ".") -> str:
    """Commit changes using GitPython"""
    try:
        git = _import_gitpython()
        repo = git.Repo(repo_path)
        commit = repo.index.commit(message)
        return f"Committed: {commit.hexsha[:8]} - {message}"
    except Exception as e:
        return f"Error committing changes: {e}"

@curry
def git_push(repo_path: str = ".") -> str:
    """Push changes using GitPython"""
    try:
        git = _import_gitpython()
        repo = git.Repo(repo_path)
        origin = repo.remote('origin')
        origin.push()
        return "Pushed changes to origin"
    except Exception as e:
        return f"Error pushing changes: {e}"

@curry
def git_pull(repo_path: str = ".") -> str:
    """Pull changes using GitPython"""
    try:
        git = _import_gitpython()
        repo = git.Repo(repo_path)
        origin = repo.remote('origin')
        origin.pull()
        return "Pulled changes from origin"
    except Exception as e:
        return f"Error pulling changes: {e}"

@curry
def git_branch(repo_path: str = ".") -> str:
    """List git branches using GitPython"""
    try:
        git = _import_gitpython()
        repo = git.Repo(repo_path)
        branches = []
        for branch in repo.branches:
            current = "* " if branch == repo.active_branch else "  "
            branches.append(f"{current}{branch.name}")
        return "\n".join(branches)
    except Exception as e:
        return f"Error getting git branches: {e}"

# Network operations
@curry
def ping(host: str) -> str:
    """Ping host using system ping command"""
    try:
        import subprocess
        result = subprocess.run(['ping', '-c', '4', host], 
                              capture_output=True, text=True, timeout=10)
        return result.stdout if result.returncode == 0 else f"Ping failed: {result.stderr}"
    except Exception as e:
        return f"Error pinging {host}: {e}"

@curry
def nmap_scan(target: str) -> str:
    """Scan target using python-nmap"""
    try:
        nmap = _import_nmap()
        nm = nmap.PortScanner()
        result = nm.scan(target, '22-443')
        
        output = []
        for host in nm.all_hosts():
            output.append(f"Host: {host} ({nm[host].hostname()})")
            output.append(f"State: {nm[host].state()}")
            
            for protocol in nm[host].all_protocols():
                ports = nm[host][protocol].keys()
                for port in ports:
                    state = nm[host][protocol][port]['state']
                    output.append(f"Port {port}/{protocol}: {state}")
        
        return "\n".join(output) if output else "No hosts found"
    except Exception as e:
        return f"Error scanning {target}: {e}"

# System information using psutil
def cpu_count() -> int:
    """Get CPU count using psutil"""
    try:
        psutil = _import_psutil()
        count = psutil.cpu_count()
        return count if count is not None else 1
    except Exception:
        return os.cpu_count() or 1

def memory_info() -> Dict[str, Any]:
    """Get memory information using psutil"""
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
    """Get disk usage using psutil"""
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

# Mathematical operations
@curry
def add(*args) -> Union[int, float, str]:
    """Add numbers or concatenate strings"""
    if not args:
        return 0
    
    result = args[0]
    for arg in args[1:]:
        if isinstance(result, str) or isinstance(arg, str):
            result = str(result) + str(arg)
        else:
            result += arg
    return result

@curry
def subtract(a: Union[int, float], b: Union[int, float]) -> Union[int, float]:
    """Subtract two numbers"""
    return a - b

@curry
def multiply(a: Union[int, float], b: Union[int, float]) -> Union[int, float]:
    """Multiply two numbers"""
    return a * b

@curry
def divide(a: Union[int, float], b: Union[int, float]) -> Union[int, float]:
    """Divide two numbers"""
    if b == 0:
        raise ValueError("Division by zero")
    return a / b

# Comparison functions that return predicates
@curry
def greater_than(threshold: Union[int, float], value: Union[int, float]) -> bool:
    """Create greater-than predicate"""
    return value > threshold

@curry
def less_than(threshold: Union[int, float], value: Union[int, float]) -> bool:
    """Create less-than predicate"""
    return value < threshold

@curry
def equals(expected: Any, value: Any) -> bool:
    """Create equality predicate"""
    return value == expected

# Higher-order functions using toolz
@curry
def map_func(func: Callable, iterable: List[Any]) -> List[Any]:
    """Functional map using toolz"""
    return list(map(func, iterable))

@curry
def filter_func(predicate: Callable, iterable: List[Any]) -> List[Any]:
    """Functional filter using toolz"""
    return list(filter(predicate, iterable))

@curry
def fold_func(func: Callable, iterable: List[Any], initial: Any = None) -> Any:
    """Functional fold/reduce using functools.reduce"""
    if initial is not None:
        return reduce(func, iterable, initial)
    else:
        return reduce(func, iterable)

# JSON operations
@curry
def jsonread(filepath: str) -> Union[Dict[str, Any], List[Any], str]:
    """Read and parse JSON file"""
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception as e:
        return f"Error reading JSON file: {e}"

@curry
def jsonwrite(data: Any, filepath: str) -> str:
    """Write data to JSON file"""
    try:
        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        return f"Data written to '{filepath}'"
    except Exception as e:
        return f"Error writing JSON file: {e}"

@curry
def jsonparse(text: str) -> Union[Dict[str, Any], List[Any], str]:
    """Parse JSON string"""
    try:
        return json.loads(text)
    except Exception as e:
        return f"Error parsing JSON: {e}"

@curry
def jsonstringify(data: Any) -> str:
    """Convert data to JSON string"""
    try:
        return json.dumps(data, indent=2, ensure_ascii=False)
    except Exception as e:
        return f"Error converting to JSON: {e}"

# CSV operations
@curry
def csvread(filepath: str, delimiter: str = ",", has_header: bool = True) -> Union[List[Dict[str, str]], List[List[str]], str]:
    """Read CSV file"""
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            if has_header:
                reader = csv.DictReader(f, delimiter=delimiter)
                return list(reader)
            else:
                reader = csv.reader(f, delimiter=delimiter)
                return list(reader)
    except Exception as e:
        return f"Error reading CSV file: {e}"

@curry
def csvwrite(data: Union[List[Dict[str, Any]], List[List[Any]]], filepath: str, delimiter: str = ",") -> str:
    """Write data to CSV file"""
    try:
        with open(filepath, 'w', newline='', encoding='utf-8') as f:
            if data and isinstance(data[0], dict):
                # Type-safe handling for dictionary data
                dict_data = [row for row in data if isinstance(row, dict)]
                if dict_data:
                    writer = csv.DictWriter(f, fieldnames=dict_data[0].keys(), delimiter=delimiter)
                    writer.writeheader()
                    writer.writerows(dict_data)
            else:
                # Handle list data
                list_data = [row for row in data if isinstance(row, list)]
                writer = csv.writer(f, delimiter=delimiter)
                writer.writerows(list_data)
        return f"Data written to '{filepath}'"
    except Exception as e:
        return f"Error writing CSV file: {e}"

# Type conversion functions
@curry
def to_number(value: Any) -> Union[int, float, str]:
    """Convert value to number"""
    try:
        if isinstance(value, str) and '.' in value:
            return float(value)
        else:
            return int(value)
    except ValueError:
        return f"Error: Cannot convert '{value}' to number"

@curry
def to_string(value: Any) -> str:
    """Convert value to string"""
    return str(value)

# Progress and utility functions
def progress(value: Any) -> Any:
    """Simple progress indicator (placeholder for now)"""
    return value

# Environment functions
@curry
def getenv(key: str, default: Optional[str] = None) -> str:
    """Get environment variable"""
    return os.getenv(key, default or "")

@curry
def setenv(key: str, value: str) -> str:
    """Set environment variable"""
    os.environ[key] = value
    return f"Set {key}={value}"

def listenv() -> Dict[str, str]:
    """List all environment variables"""
    return dict(os.environ)

# Create a function map for easy lookup
FUNCTION_MAP = {
    # Filesystem operations
    'ls': ls,
    'pwd': pwd,
    'mkdir': mkdir,
    'rm': rm,
    'echo': echo,
    'read': read_file,
    'write': write_file,
    'cp': cp,
    'mv': mv,
    'touch': touch,
    'find': find,
    
    # Web operations
    'wget': wget,
    'get': get,
    'post': post,
    
    # Hash functions
    'md5': md5,
    'sha256': sha256,
    
    # Git operations
    'git_status': git_status,
    'git_add': git_add,
    'git_commit': git_commit,
    'git_push': git_push,
    'git_pull': git_pull,
    'git_branch': git_branch,
    
    # Network operations
    'ping': ping,
    'nmap': nmap_scan,
    
    # System information
    'cpu_count': cpu_count,
    'memory': memory_info,
    'disk_usage': disk_usage,
    
    # Mathematical operations
    '+': add,
    '-': subtract,
    '*': multiply,
    '/': divide,
    
    # Comparison functions
    '>': greater_than,
    '<': less_than,
    '==': equals,
    
    # Higher-order functions
    'map': map_func,
    'filter': filter_func,
    'fold': fold_func,
    
    # JSON operations
    'jsonread': jsonread,
    'jsonwrite': jsonwrite,
    'jsonparse': jsonparse,
    'jsonstringify': jsonstringify,
    
    # CSV operations
    'csvread': csvread,
    'csvwrite': csvwrite,
    
    # Type conversion
    'to_number': to_number,
    'to_string': to_string,
    
    # Utility functions
    'progress': progress,
    'getenv': getenv,
    'setenv': setenv,
    'listenv': listenv,
}
