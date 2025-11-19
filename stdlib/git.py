"""
Sol Standard Library - Git Operations Module
Provides Git version control system operations.
"""
from typing import List
from toolz import curry


def _import_gitpython():
    """Lazy import GitPython library."""
    try:
        import git
        return git
    except ImportError:
        raise ImportError(
            "GitPython library not found. Install with: pip install GitPython")


@curry
def git_status(repo_path: str = ".") -> str:
    """
    Get git repository status.

    Args:
        repo_path: Path to git repository (default: current directory)

    Returns:
        Status message showing modified and untracked files

    Examples:
        >>> git_status()
        'Modified files:\\n  M main.py\\nUntracked files:\\n  ?? temp.txt'
        >>> git_status("/path/to/repo")
        'Working directory clean'

    Errors:
        - InvalidGitRepositoryError: Not a git repository
        - NoSuchPathError: Path doesn't exist
    """
    try:
        git = _import_gitpython()
        repo = git.Repo(repo_path)

        modified_status = (
            ["Modified files:"] +
            [f"  M {item.a_path}" for item in repo.index.diff(None)]
            if repo.is_dirty()
            else []
        )

        untracked_status = (
            ["Untracked files:"] +
            [f"  ?? {file}" for file in repo.untracked_files]
            if repo.untracked_files
            else []
        )

        status_output = modified_status + untracked_status
        return "\n".join(status_output if status_output else ["Working directory clean"])
    except Exception as e:
        return f"Error getting git status: {e}"


@curry
def git_add(file_path: str, repo_path: str = ".") -> str:
    """
    Add file to git staging area.

    Args:
        file_path: Path to file to add
        repo_path: Path to git repository (default: current directory)

    Returns:
        Success message or error description

    Examples:
        >>> git_add("main.py")
        "Added 'main.py' to git index"

    Errors:
        - InvalidGitRepositoryError: Not a git repository
        - FileNotFoundError: File doesn't exist
    """
    try:
        git = _import_gitpython()
        repo = git.Repo(repo_path)
        repo.index.add([file_path])
        return f"Added '{file_path}' to git index"
    except Exception as e:
        return f"Error adding file to git: {e}"


@curry
def git_commit(message: str, repo_path: str = ".") -> str:
    """
    Commit staged changes with message.

    Args:
        message: Commit message
        repo_path: Path to git repository (default: current directory)

    Returns:
        Commit info or error description

    Examples:
        >>> git_commit("Fix bug in parser")
        "Committed: a1b2c3d4 - Fix bug in parser"

    Errors:
        - InvalidGitRepositoryError: Not a git repository
        - GitCommandError: Nothing to commit or other git error
    """
    try:
        git = _import_gitpython()
        repo = git.Repo(repo_path)
        commit = repo.index.commit(message)
        return f"Committed: {commit.hexsha[:8]} - {message}"
    except Exception as e:
        return f"Error committing changes: {e}"


@curry
def git_push(repo_path: str = ".") -> str:
    """
    Push commits to remote origin.

    Args:
        repo_path: Path to git repository (default: current directory)

    Returns:
        Success message or error description

    Examples:
        >>> git_push()
        "Pushed changes to origin"

    Errors:
        - InvalidGitRepositoryError: Not a git repository
        - GitCommandError: No remote 'origin' or push failed
        - PermissionError: Authentication failed
    """
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
    """
    Pull changes from remote origin.

    Args:
        repo_path: Path to git repository (default: current directory)

    Returns:
        Success message or error description

    Examples:
        >>> git_pull()
        "Pulled changes from origin"

    Errors:
        - InvalidGitRepositoryError: Not a git repository
        - GitCommandError: No remote 'origin' or pull failed
        - MergeConflict: Merge conflicts occurred
    """
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
    """
    List all branches with current branch marked.

    Args:
        repo_path: Path to git repository (default: current directory)

    Returns:
        Formatted branch list or error description

    Examples:
        >>> git_branch()
        '* main\\n  develop\\n  feature/new-parser'

    Errors:
        - InvalidGitRepositoryError: Not a git repository
    """
    try:
        git = _import_gitpython()
        repo = git.Repo(repo_path)

        return "\n".join([
            f"{'* ' if branch == repo.active_branch else '  '}{branch.name}"
            for branch in repo.branches
        ])
    except Exception as e:
        return f"Error getting git branches: {e}"


# Export all functions
__all__ = [
    'git_status', 'git_add', 'git_commit',
    'git_push', 'git_pull', 'git_branch'
]
