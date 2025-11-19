"""
Sol Standard Library - Conversion Module
Provides type conversion functions.
"""
from typing import Any, Union
from toolz import curry


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


def progress(value: Any) -> Any:
    """
    Pass-through function (placeholder for progress indicator).

    Args:
        value: Value to pass through

    Returns:
        The same value unchanged

    Examples:
        >>> progress(42)
        42
        >>> progress("hello")
        'hello'

    Notes:
        Future: Could be enhanced to show progress bars
    """
    return value


# Export all functions
__all__ = ['to_number', 'to_string', 'progress']
