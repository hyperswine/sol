"""
Sol Standard Library - Operators Module
Provides mathematical, comparison, and higher-order functions.
"""
from typing import Any, Callable, List, Union
from functools import reduce
from toolz import curry


# Mathematical operators

@curry
def add(*args) -> Union[int, float, str]:
    """
    Add numbers or concatenate strings.

    Args:
        *args: Numbers to add or strings to concatenate

    Returns:
        Sum of numbers or concatenated string

    Examples:
        >>> add(1, 2, 3)
        6
        >>> add(1.5, 2.5)
        4.0
        >>> add("Hello", " ", "World")
        'Hello World'
        >>> add()
        0

    Notes:
        If any argument is a string, all are converted to strings
    """
    if not args:
        return 0

    def add_two(a, b):
        """Helper to add/concatenate two values."""
        if isinstance(a, str) or isinstance(b, str):
            return str(a) + str(b)
        else:
            return a + b

    return reduce(add_two, args)


@curry
def subtract(a: Union[int, float], b: Union[int, float]) -> Union[int, float]:
    """
    Subtract two numbers.

    Args:
        a: Minuend (number to subtract from)
        b: Subtrahend (number to subtract)

    Returns:
        Difference (a - b)

    Examples:
        >>> subtract(10, 3)
        7
        >>> subtract(5.5, 2.5)
        3.0
    """
    return a - b


@curry
def multiply(a: Union[int, float], b: Union[int, float]) -> Union[int, float]:
    """
    Multiply two numbers.

    Args:
        a: First multiplicand
        b: Second multiplicand

    Returns:
        Product (a * b)

    Examples:
        >>> multiply(3, 4)
        12
        >>> multiply(2.5, 4)
        10.0
    """
    return a * b


@curry
def divide(a: Union[int, float], b: Union[int, float]) -> Union[int, float]:
    """
    Divide two numbers.

    Args:
        a: Dividend (number to be divided)
        b: Divisor (number to divide by)

    Returns:
        Quotient (a / b)

    Examples:
        >>> divide(10, 2)
        5.0
        >>> divide(7, 2)
        3.5

    Errors:
        - ValueError: Division by zero
    """
    if b == 0:
        raise ValueError("Division by zero")
    return a / b


# Comparison operators

@curry
def greater_than(threshold: Union[int, float], value: Union[int, float]) -> bool:
    """
    Create greater-than predicate (curried).

    Args:
        threshold: Value to compare against
        value: Value to check

    Returns:
        True if value > threshold

    Examples:
        >>> greater_than(5, 10)
        True
        >>> greater_than(5, 3)
        False
        >>> is_big = greater_than(100)  # Partial application
        >>> is_big(150)
        True
    """
    return value > threshold


@curry
def less_than(threshold: Union[int, float], value: Union[int, float]) -> bool:
    """
    Create less-than predicate (curried).

    Args:
        threshold: Value to compare against
        value: Value to check

    Returns:
        True if value < threshold

    Examples:
        >>> less_than(5, 3)
        True
        >>> less_than(5, 10)
        False
        >>> is_small = less_than(10)  # Partial application
        >>> is_small(5)
        True
    """
    return value < threshold


@curry
def equals(expected: Any, value: Any) -> bool:
    """
    Create equality predicate (curried).

    Args:
        expected: Expected value
        value: Value to check

    Returns:
        True if value == expected

    Examples:
        >>> equals(42, 42)
        True
        >>> equals("hello", "world")
        False
        >>> is_zero = equals(0)  # Partial application
        >>> is_zero(0)
        True
    """
    return value == expected


# Higher-order functions

@curry
def map_func(func: Callable, iterable: List[Any]) -> List[Any]:
    """
    Apply function to each element of iterable.

    Args:
        func: Function to apply to each element
        iterable: List of elements to transform

    Returns:
        List of transformed elements

    Examples:
        >>> map_func(lambda x: x * 2, [1, 2, 3])
        [2, 4, 6]
        >>> double = map_func(lambda x: x * 2)  # Partial
        >>> double([1, 2, 3])
        [2, 4, 6]

    Notes:
        This is a curried version of Python's built-in map
    """
    return list(map(func, iterable))


@curry
def filter_func(predicate: Callable, iterable: List[Any]) -> List[Any]:
    """
    Filter elements that satisfy predicate.

    Args:
        predicate: Function returning True for elements to keep
        iterable: List of elements to filter

    Returns:
        List of elements where predicate returned True

    Examples:
        >>> filter_func(lambda x: x > 5, [1, 6, 3, 8, 2])
        [6, 8]
        >>> is_even = lambda x: x % 2 == 0
        >>> filter_func(is_even, [1, 2, 3, 4])
        [2, 4]

    Notes:
        This is a curried version of Python's built-in filter
    """
    return list(filter(predicate, iterable))


@curry
def fold_func(func: Callable, iterable: List[Any], initial: Any = None) -> Any:
    """
    Reduce iterable to single value using binary function.

    Args:
        func: Binary function to apply cumulatively
        iterable: List of elements to reduce
        initial: Initial value (optional)

    Returns:
        Single accumulated value

    Examples:
        >>> fold_func(lambda a, b: a + b, [1, 2, 3, 4], 0)
        10
        >>> fold_func(lambda a, b: a * b, [1, 2, 3, 4], 1)
        24
        >>> sum_all = fold_func(lambda a, b: a + b)  # Partial
        >>> sum_all([1, 2, 3], 0)
        6

    Notes:
        Also known as reduce or aggregate.
        If no initial value, uses first element.
    """
    if initial is not None:
        return reduce(func, iterable, initial)
    else:
        return reduce(func, iterable)


# Export all functions
__all__ = [
    'add', 'subtract', 'multiply', 'divide',
    'greater_than', 'less_than', 'equals',
    'map_func', 'filter_func', 'fold_func'
]
