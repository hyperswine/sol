"""
Sol Standard Library - Result Type
Provides Result type and unwrap functions for error handling.
"""
from typing import Any, Union, Dict, Optional
from dataclasses import dataclass


@dataclass
class Result:
    """
    Result type for operations that can succeed or fail.
    Contains either a success value or an error.
    """
    success: bool
    value: Any = None
    error: Optional[str] = None

    def __str__(self):
        if self.success:
            return f"Ok({self.value})"
        else:
            return f"Err({self.error})"

    def is_ok(self):
        """Check if result is successful"""
        return self.success

    def is_err(self):
        """Check if result is an error"""
        return not self.success


def ok(value: Any) -> Result:
    """Create a successful Result"""
    return Result(success=True, value=value)


def err(error: str) -> Result:
    """Create an error Result"""
    return Result(success=False, error=error)


def unwrap_or(result: Any, default_value: Any) -> Any:
    """
    Unwrap a Result, returning the value if Ok, or the default if Err.
    If result is not a Result type, return it as-is.
    """
    if isinstance(result, Result):
        if result.is_ok():
            return result.value
        else:
            return default_value
    # If it's not a Result, just return it
    return result


def unwrap_or_exit(result: Any, error_message: Optional[str] = None) -> Any:
    """
    Unwrap a Result, returning the value if Ok, or exiting with error if Err.
    If result is not a Result type, return it as-is.
    """
    if isinstance(result, Result):
        if result.is_ok():
            return result.value
        else:
            # Print error and exit
            if error_message:
                print(f"Error: {error_message}")
            if result.error:
                print(f"  Details: {result.error}")
            import sys
            sys.exit(1)
    # If it's not a Result, just return it
    return result


def failed(result: Any) -> bool:
    """
    Check if a Result has failed.
    Returns True if result is an Err, False otherwise.
    """
    if isinstance(result, Result):
        return result.is_err()
    # If it's not a Result, consider it successful
    return False


def succeeded(result: Any) -> bool:
    """
    Check if a Result has succeeded.
    Returns True if result is an Ok, False otherwise.
    """
    if isinstance(result, Result):
        return result.is_ok()
    # If it's not a Result, consider it successful
    return True
