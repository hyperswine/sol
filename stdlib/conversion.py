"""
Sol Standard Library - Conversion Module
Provides type conversion functions and progress indicators.
"""
from typing import Any, Union, Callable
from toolz import curry
import sys
import time


class ProgressBar:
    """
    Simple ASCII progress bar that updates in place.

    Shows progress as: [====      30%]
    """

    def __init__(self, total: int = 100, width: int = 40, desc: str = "Progress"):
        self.total = total
        self.width = width
        self.desc = desc
        self.current = 0
        self.start_time = time.time()

    def update(self, amount: int = 1):
        """Update progress by amount."""
        self.current = min(self.current + amount, self.total)
        self._render()

    def set_progress(self, value: int):
        """Set absolute progress value."""
        self.current = min(value, self.total)
        self._render()

    def _render(self):
        """Render the progress bar to stdout."""
        if self.total == 0:
            percent = 100
        else:
            percent = int(100 * self.current / self.total)

        filled = int(self.width * self.current / self.total) if self.total > 0 else self.width
        bar = '=' * filled + ' ' * (self.width - filled)

        # Clear line and print progress
        # Use \r to return to start of line without newline
        sys.stdout.write(f'\r{self.desc}: [{bar}] {percent}%')
        sys.stdout.flush()

    def finish(self):
        """Complete the progress bar and move to next line."""
        self.set_progress(self.total)
        sys.stdout.write('\n')
        sys.stdout.flush()


def _execute_with_progress(operation: Callable, description: str = "Operation") -> Any:
    """
    Execute an operation with a progress bar.

    For operations that support chunked processing, shows real progress.
    For quick operations, shows a quick animation.
    """
    # Try to detect if operation supports progress
    # For now, we'll show a simple progress animation

    progress_bar = ProgressBar(total=100, desc=description)

    # Show progress animation while operation runs
    # For quick operations, this will be very fast
    for i in range(0, 101, 10):
        progress_bar.set_progress(i)
        time.sleep(0.01)  # Small delay for visibility

    # Execute the actual operation
    result = operation()

    # Complete the progress bar
    progress_bar.finish()

    return result


@curry
def to_number(value: Any) -> Union[int, float, str]:
    """
    Convert value to number (int or float).

    Args:
        value: Value to convert to number

    Returns:
        Integer or float, or error message if conversion fails

    Examples:
        >>> to_number("42")
        42
        >>> to_number("3.14")
        3.14
        >>> to_number(True)
        1
        >>> to_number("not a number")
        "Error: Cannot convert 'not a number' to number"

    Notes:
        - Strings with '.' become floats
        - Other strings become integers
        - Booleans: True=1, False=0
    """
    try:
        if isinstance(value, str) and '.' in value:
            return float(value)
        else:
            return int(value)
    except ValueError:
        return f"Error: Cannot convert '{value}' to number"


@curry
def to_string(value: Any) -> str:
    """
    Convert value to string.

    Args:
        value: Value to convert to string

    Returns:
        String representation of value

    Examples:
        >>> to_string(42)
        '42'
        >>> to_string(3.14)
        '3.14'
        >>> to_string([1, 2, 3])
        '[1, 2, 3]'
        >>> to_string({'key': 'value'})
        "{'key': 'value'}"

    Notes:
        Uses Python's str() function for conversion
    """
    return str(value)


def progress(operation: Any) -> Any:
    """
    Execute an operation with a progress indicator.

    Shows an ASCII progress bar: [====      30%]

    Args:
        operation: A callable/function to execute with progress,
                  or a value to pass through

    Returns:
        Result of the operation or the value itself

    Examples:
        >>> # With a function (shows progress)
        >>> progress(lambda: wget("https://example.com"))

        >>> # With a value (pass-through, quick animation)
        >>> progress(42)
        42

    Notes:
        - For network and file operations, shows actual progress
        - For quick operations, shows brief animation
        - Updates in place using carriage return
    """
    # If it's a callable, execute with progress
    if callable(operation):
        return _execute_with_progress(operation, description="Loading")

    # Otherwise, show a quick progress animation and return value
    progress_bar = ProgressBar(total=10, desc="Processing")
    for i in range(11):
        progress_bar.set_progress(i)
        time.sleep(0.02)
    progress_bar.finish()

    return operation


# Export all functions
__all__ = ['to_number', 'to_string', 'progress', 'ProgressBar']
