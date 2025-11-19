#!/usr/bin/env python3
"""
Test script for new Sol features:
1. Result types with unwrap_or and unwrap_or_exit
2. Pipeline operator |>
3. F-strings with double quotes
"""

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent))

from parsing import create_parser
from interpret import create_interpreter

def test_result_types():
    """Test Result type and unwrap functions"""
    print("=" * 60)
    print("Testing Result Types")
    print("=" * 60)

    parser = create_parser()
    interpreter = create_interpreter()

    # Test 1: Basic Result type with unwrap_or
    code1 = '''
version = getenv "MISSING_VAR".
result = unwrap_or version "default_value".
echo result.
'''
    print("\nTest 1: unwrap_or with missing env var")
    print(f"Code: {code1.strip()}")
    parsed = parser.parse(code1)
    interpreter.run(parsed)

    # Test 2: sh command returning Result
    code2 = '''
cmd_result = sh "echo hello".
output = unwrap_or cmd_result "failed".
echo output.
'''
    print("\nTest 2: sh command with Result type")
    print(f"Code: {code2.strip()}")
    parsed = parser.parse(code2)
    interpreter.run(parsed)

    # Test 3: failed function
    code3 = '''
good = sh "echo test".
bad = sh "false".
echo (failed good).
echo (failed bad).
'''
    print("\nTest 3: failed function to check Result status")
    print(f"Code: {code3.strip()}")
    parsed = parser.parse(code3)
    interpreter.run(parsed)


def test_pipelines():
    """Test pipeline operator |>"""
    print("\n" + "=" * 60)
    print("Testing Pipeline Operator |>")
    print("=" * 60)

    parser = create_parser()
    interpreter = create_interpreter()

    # Test 1: Simple pipeline
    code1 = '''
result = getenv "HOME" |> echo.
'''
    print("\nTest 1: Simple pipeline with getenv |> echo")
    print(f"Code: {code1.strip()}")
    parsed = parser.parse(code1)
    interpreter.run(parsed)

    # Test 2: Pipeline with unwrap_or
    code2 = '''
version = getenv "MISSING" |> unwrap_or "latest".
echo version.
'''
    print("\nTest 2: Pipeline with unwrap_or")
    print(f"Code: {code2.strip()}")
    parsed = parser.parse(code2)
    interpreter.run(parsed)

    # Test 3: Multi-stage pipeline
    code3 = '''
nums = [1, 2, 3, 4, 5].
add_one x = + x 1.
result = nums |> map add_one.
echo result.
'''
    print("\nTest 3: Pipeline with map")
    print(f"Code: {code3.strip()}")
    parsed = parser.parse(code3)
    interpreter.run(parsed)


def test_fstrings():
    """Test f-strings with double quotes"""
    print("\n" + "=" * 60)
    print("Testing F-Strings")
    print("=" * 60)

    parser = create_parser()
    interpreter = create_interpreter()

    # Test 1: Basic f-string
    code1 = '''
name = "World".
echo "Hello, {name}!".
'''
    print("\nTest 1: Basic f-string interpolation")
    print(f"Code: {code1.strip()}")
    parsed = parser.parse(code1)
    interpreter.run(parsed)

    # Test 2: Multiple variables in f-string
    code2 = '''
service = "api".
version = "v1.2.3".
echo "Building {service}:{version}...".
'''
    print("\nTest 2: Multiple variables in f-string")
    print(f"Code: {code2.strip()}")
    parsed = parser.parse(code2)
    interpreter.run(parsed)

    # Test 3: F-string with regular string comparison
    code3 = '''
x = "test".
echo "Variable is: {x}".
echo 'This is a regular string'.
'''
    print("\nTest 3: F-string vs regular string")
    print(f"Code: {code3.strip()}")
    parsed = parser.parse(code3)
    interpreter.run(parsed)


def test_combined_features():
    """Test all features together"""
    print("\n" + "=" * 60)
    print("Testing Combined Features")
    print("=" * 60)

    parser = create_parser()
    interpreter = create_interpreter()

    # Complex example combining all features
    code = '''
version = getenv "VERSION" |> unwrap_or "latest".
registry = getenv "REGISTRY" |> unwrap_or "registry.io".
service = "myapp".
echo "Deploying {service}:{version} to {registry}".
'''
    print("\nCombined test: Pipeline, Result, and F-strings")
    print(f"Code: {code.strip()}")
    parsed = parser.parse(code)
    interpreter.run(parsed)


if __name__ == "__main__":
    try:
        test_result_types()
        test_pipelines()
        test_fstrings()
        test_combined_features()
        print("\n" + "=" * 60)
        print("All tests completed!")
        print("=" * 60)
    except Exception as e:
        print(f"\nError during testing: {e}")
        import traceback
        traceback.print_exc()
