"""
Sol Standard Library - Main Module
Exports all stdlib functions via FUNCTION_MAP.
"""

# Import all modules
from . import filesystem
from . import network
from . import git
from . import data
from . import system
from . import hashing
from . import operators
from . import conversion
from . import result


# Build the FUNCTION_MAP by aggregating all module functions
FUNCTION_MAP = {
    # Filesystem operations
    'ls': filesystem.ls,
    'pwd': filesystem.pwd,
    'mkdir': filesystem.mkdir,
    'rm': filesystem.rm,
    'echo': filesystem.echo,
    'read': filesystem.read_file,
    'write': filesystem.write_file,
    'cp': filesystem.cp,
    'mv': filesystem.mv,
    'touch': filesystem.touch,
    'find': filesystem.find,

    # Network operations
    'wget': network.wget,
    'get': network.get,
    'post': network.post,
    'ping': network.ping,
    'nmap': network.nmap_scan,

    # Git operations
    'git_status': git.git_status,
    'git_add': git.git_add,
    'git_commit': git.git_commit,
    'git_push': git.git_push,
    'git_pull': git.git_pull,
    'git_branch': git.git_branch,

    # Data operations (JSON & CSV)
    'jsonread': data.jsonread,
    'jsonwrite': data.jsonwrite,
    'jsonparse': data.jsonparse,
    'jsonstringify': data.jsonstringify,
    'csvread': data.csvread,
    'csvwrite': data.csvwrite,

    # System information
    'cpu_count': system.cpu_count,
    'memory': system.memory_info,
    'disk_usage': system.disk_usage,
    'getenv': system.getenv,
    'setenv': system.setenv,
    'listenv': system.listenv,
    'sh': system.sh,
    'exit': system.exit_cmd,

    # Hashing functions
    'md5': hashing.md5,
    'sha256': hashing.sha256,

    # Mathematical operators
    '+': operators.add,
    '-': operators.subtract,
    '*': operators.multiply,
    '/': operators.divide,

    # Comparison operators
    '>': operators.greater_than,
    '<': operators.less_than,
    '==': operators.equals,

    # Higher-order functions
    'map': operators.map_func,
    'filter': operators.filter_func,
    'fold': operators.fold_func,

    # Type conversion
    'to_number': conversion.to_number,
    'to_string': conversion.to_string,
    'progress': conversion.progress,

    # Result type functions
    'unwrap_or': result.unwrap_or,
    'unwrap_or_exit': result.unwrap_or_exit,
    'failed': result.failed,
    'succeeded': result.succeeded,
}


# Export FUNCTION_MAP as the main interface
__all__ = ['FUNCTION_MAP']
