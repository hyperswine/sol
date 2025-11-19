"""
Sol Standard Library - Data Operations Module
Provides JSON and CSV data processing functions.
"""
import json
import csv
from typing import Any, Dict, List, Union
from toolz import curry


@curry
def jsonread(filepath: str) -> Union[Dict[str, Any], List[Any], str]:
    """
    Read and parse JSON file.

    Args:
        filepath: Path to JSON file

    Returns:
        Parsed JSON data (dict/list) or error message

    Examples:
        >>> jsonread("config.json")
        {'name': 'Sol', 'version': '0.2.0'}

    Errors:
        - FileNotFoundError: File doesn't exist
        - JSONDecodeError: Invalid JSON syntax
        - PermissionError: No read access
    """
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception as e:
        return f"Error reading JSON file: {e}"


@curry
def jsonwrite(data: Any, filepath: str) -> str:
    """
    Write data to JSON file with pretty formatting.

    Args:
        data: Data to serialize (dict, list, etc.)
        filepath: Path to output JSON file

    Returns:
        Success message or error description

    Examples:
        >>> jsonwrite({'key': 'value'}, "output.json")
        "Data written to 'output.json'"

    Errors:
        - TypeError: Data not JSON serializable
        - PermissionError: No write access
    """
    try:
        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        return f"Data written to '{filepath}'"
    except Exception as e:
        return f"Error writing JSON file: {e}"


@curry
def jsonparse(text: str) -> Union[Dict[str, Any], List[Any], str]:
    """
    Parse JSON string to data structure.

    Args:
        text: JSON string to parse

    Returns:
        Parsed JSON data (dict/list) or error message

    Examples:
        >>> jsonparse('{"name": "Sol", "age": 1}')
        {'name': 'Sol', 'age': 1}
        >>> jsonparse('[1, 2, 3]')
        [1, 2, 3]

    Errors:
        - JSONDecodeError: Invalid JSON syntax
    """
    try:
        return json.loads(text)
    except Exception as e:
        return f"Error parsing JSON: {e}"


@curry
def jsonstringify(data: Any) -> str:
    """
    Convert data to pretty-printed JSON string.

    Args:
        data: Data to serialize (dict, list, etc.)

    Returns:
        JSON string or error message

    Examples:
        >>> jsonstringify({'name': 'Sol'})
        '{\\n  "name": "Sol"\\n}'

    Errors:
        - TypeError: Data not JSON serializable
    """
    try:
        return json.dumps(data, indent=2, ensure_ascii=False)
    except Exception as e:
        return f"Error converting to JSON: {e}"


@curry
def csvread(filepath: str, delimiter: str = ",", has_header: bool = True) -> Union[List[Dict[str, str]], List[List[str]], str]:
    """
    Read CSV file as list of dictionaries or lists.

    Args:
        filepath: Path to CSV file
        delimiter: Column delimiter (default: ",")
        has_header: Whether first row is header (default: True)

    Returns:
        List of dicts (if header) or list of lists, or error message

    Examples:
        >>> csvread("data.csv")
        [{'name': 'Alice', 'age': '30'}, {'name': 'Bob', 'age': '25'}]
        >>> csvread("data.tsv", delimiter="\\t", has_header=False)
        [['Alice', '30'], ['Bob', '25']]

    Errors:
        - FileNotFoundError: File doesn't exist
        - PermissionError: No read access
        - UnicodeDecodeError: Invalid encoding
    """
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
    """
    Write data to CSV file.

    Args:
        data: List of dicts or list of lists to write
        filepath: Path to output CSV file
        delimiter: Column delimiter (default: ",")

    Returns:
        Success message or error description

    Examples:
        >>> csvwrite([{'name': 'Alice', 'age': 30}], "output.csv")
        "Data written to 'output.csv'"
        >>> csvwrite([['Alice', 30], ['Bob', 25]], "output.csv")
        "Data written to 'output.csv'"

    Errors:
        - PermissionError: No write access
        - TypeError: Invalid data structure
    """
    try:
        with open(filepath, 'w', newline='', encoding='utf-8') as f:
            if data and isinstance(data[0], dict):
                # Dictionary data
                dict_data = [row for row in data if isinstance(row, dict)]
                if dict_data:
                    writer = csv.DictWriter(
                        f, fieldnames=dict_data[0].keys(), delimiter=delimiter)
                    writer.writeheader()
                    writer.writerows(dict_data)
            else:
                # List data
                list_data = [row for row in data if isinstance(row, list)]
                writer = csv.writer(f, delimiter=delimiter)
                writer.writerows(list_data)
        return f"Data written to '{filepath}'"
    except Exception as e:
        return f"Error writing CSV file: {e}"


# Export all functions
__all__ = [
    'jsonread', 'jsonwrite', 'jsonparse', 'jsonstringify',
    'csvread', 'csvwrite'
]
