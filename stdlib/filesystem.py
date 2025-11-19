"""
Sol Standard Library - Filesystem Operations Module
Provides file and directory manipulation functions.
"""
import os
import shutil
from pathlib import Path
from typing import Any, List, Union, Optional
from functools import partial
from toolz import curry


@curry
def ls(path: Optional[str] = None) -> Union[List[str], str]:
    """
    List directory contents.

    Args:
        path: Directory path (default: current directory)

    Returns:
        List of file/directory names or error message

    Examples:
        >>> ls()
        ['file1.txt', 'file2.py', 'dir1']
        >>> ls("/tmp")
        ['temp1', 'temp2']

    Errors:
        - FileNotFoundError: Directory doesn't exist
        - PermissionError: No read access
    """
    target_path = Path(path or os.getcwd())
    try:
        return [item.name for item in target_path.iterdir()]
    except FileNotFoundError:
        return f"Error: Directory '{target_path}' not found"
    except PermissionError:
        return f"Error: Permission denied accessing '{target_path}'"


def pwd() -> str:
    """
    Get current working directory.

    Returns:
        Absolute path to current directory as string

    Examples:
        >>> pwd()
        '/home/user/projects'
    """
    return str(Path.cwd())


@curry
def mkdir(path: str) -> str:
    """
    Create directory with parent directories.

    Args:
        path: Directory path to create

    Returns:
        Success message or error description

    Examples:
        >>> mkdir("project/src/lib")
        "Directory 'project/src/lib' created"

    Errors:
        - PermissionError: No write access
        - OSError: System-level error
    """
    try:
        Path(path).mkdir(parents=True, exist_ok=True)
        return f"Directory '{path}' created"
    except Exception as e:
        return f"Error creating directory: {e}"


@curry
def rm(path: str) -> str:
    """
    Remove file or directory.

    Args:
        path: File or directory path to remove

    Returns:
        Success message or error description

    Examples:
        >>> rm("temp.txt")
        "File 'temp.txt' removed"
        >>> rm("old_dir")
        "Directory 'old_dir' removed"

    Errors:
        - FileNotFoundError: Path doesn't exist
        - PermissionError: No delete access
        - OSError: Directory not empty
    """
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
    """
    Convert value to string (print equivalent).

    Args:
        text: Any value to convert to string

    Returns:
        String representation of input

    Examples:
        >>> echo("Hello")
        "Hello"
        >>> echo(42)
        "42"
    """
    return str(text)


@curry
def read_file(path: str) -> str:
    """
    Read entire file contents as string.

    Args:
        path: File path to read

    Returns:
        File contents as string or error message

    Examples:
        >>> read_file("config.txt")
        "key=value\\nfoo=bar"

    Errors:
        - FileNotFoundError: File doesn't exist
        - PermissionError: No read access
        - UnicodeDecodeError: File not UTF-8 encoded
    """
    try:
        return Path(path).read_text(encoding='utf-8')
    except Exception as e:
        return f"Error reading file: {e}"


@curry
def write_file(path: str, content: str) -> str:
    """
    Write string content to file (overwrites existing).

    Args:
        path: File path to write
        content: String content to write

    Returns:
        Success message or error description

    Examples:
        >>> write_file("output.txt", "Hello World")
        "Content written to 'output.txt'"

    Errors:
        - PermissionError: No write access
        - OSError: Disk full or other system error
    """
    try:
        Path(path).write_text(content, encoding='utf-8')
        return f"Content written to '{path}'"
    except Exception as e:
        return f"Error writing file: {e}"


@curry
def cp(src: str, dst: str) -> str:
    """
    Copy file from source to destination.

    Args:
        src: Source file path
        dst: Destination file path

    Returns:
        Success message or error description

    Examples:
        >>> cp("file.txt", "backup.txt")
        "Copied 'file.txt' to 'backup.txt'"

    Errors:
        - FileNotFoundError: Source doesn't exist
        - PermissionError: No read/write access
        - IsADirectoryError: Destination is directory
    """
    try:
        shutil.copy2(src, dst)
        return f"Copied '{src}' to '{dst}'"
    except Exception as e:
        return f"Error copying file: {e}"


@curry
def mv(src: str, dst: str) -> str:
    """
    Move/rename file from source to destination.

    Args:
        src: Source file path
        dst: Destination file path

    Returns:
        Success message or error description

    Examples:
        >>> mv("old.txt", "new.txt")
        "Moved 'old.txt' to 'new.txt'"

    Errors:
        - FileNotFoundError: Source doesn't exist
        - PermissionError: No write access
        - OSError: Cross-device link
    """
    try:
        Path(src).rename(dst)
        return f"Moved '{src}' to '{dst}'"
    except Exception as e:
        return f"Error moving file: {e}"


@curry
def touch(path: str) -> str:
    """
    Create empty file or update timestamp.

    Args:
        path: File path to create/touch

    Returns:
        Success message or error description

    Examples:
        >>> touch("newfile.txt")
        "Created 'newfile.txt'"

    Errors:
        - PermissionError: No write access
    """
    try:
        Path(path).touch()
        return f"Created '{path}'"
    except Exception as e:
        return f"Error creating file: {e}"


@curry
def find(pattern: str, path: str = ".") -> List[str]:
    """
    Find files matching glob pattern recursively.

    Args:
        pattern: Glob pattern (e.g., "*.py", "**/*.txt")
        path: Starting directory (default: current)

    Returns:
        List of matching file paths or error message

    Examples:
        >>> find("*.py")
        ['main.py', 'test.py', 'lib/utils.py']
        >>> find("**/*.json", "/config")
        ['/config/app.json', '/config/data/settings.json']

    Errors:
        - PermissionError: No read access to directory
    """
    try:
        target_path = Path(path)
        return [str(p) for p in target_path.rglob(pattern)]
    except Exception as e:
        return [f"Error finding files: {e}"]


# Export all functions
__all__ = [
    'ls', 'pwd', 'mkdir', 'rm', 'echo',
    'read_file', 'write_file', 'cp', 'mv', 'touch', 'find'
]
