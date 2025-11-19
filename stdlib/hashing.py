"""
Sol Standard Library - Hashing Module
Provides cryptographic hash functions.
"""
import hashlib
from typing import Any
from toolz import curry


@curry
def md5(text: Any) -> str:
    """
    Calculate MD5 hash of text.

    Args:
        text: Text or value to hash (converted to string)

    Returns:
        32-character hexadecimal MD5 hash

    Examples:
        >>> md5("hello")
        '5d41402abc4b2a76b9719d911017c592'
        >>> md5(42)
        'a1d0c6e83f027327d8461063f4ac58a6'

    Notes:
        MD5 is NOT cryptographically secure.
        Use for checksums only, not passwords or security.
    """
    return hashlib.md5(str(text).encode()).hexdigest()


@curry
def sha256(text: Any) -> str:
    """
    Calculate SHA-256 hash of text.

    Args:
        text: Text or value to hash (converted to string)

    Returns:
        64-character hexadecimal SHA-256 hash

    Examples:
        >>> sha256("hello")
        '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'
        >>> sha256(42)
        '73475cb40a568e8da8a045ced110137e159f890ac4da883b6b17dc651b3a8049'

    Notes:
        SHA-256 is cryptographically secure and suitable for:
        - Password hashing (with salt)
        - Data integrity verification
        - Digital signatures
    """
    return hashlib.sha256(str(text).encode()).hexdigest()


# Export all functions
__all__ = ['md5', 'sha256']
