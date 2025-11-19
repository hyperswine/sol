#!/usr/bin/env python3
"""
Sol Test Runner
Runs all tests in the tests/ directory with a nice summary.

Usage:
  python run_tests.py              # Run all tests
  python run_tests.py features     # Run feature tests only
  python run_tests.py repl         # Run REPL tests only
  python run_tests.py performance  # Run performance tests only
  python run_tests.py -v           # Verbose mode
"""

import sys
import os
import subprocess
from pathlib import Path
from typing import List, Tuple, Optional
import argparse
import time

# Add parent directory to path so tests can import modules
sys.path.insert(0, str(Path(__file__).parent))

# Color codes for pretty output
class Colors:
    GREEN = '\033[92m'
    RED = '\033[91m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    BOLD = '\033[1m'
    END = '\033[0m'

def colored(text: str, color: str) -> str:
    """Return colored text for terminal output"""
    return f"{color}{text}{Colors.END}"

def print_header(text: str):
    """Print a formatted header"""
    print()
    print("=" * 70)
    print(colored(text, Colors.BOLD + Colors.BLUE))
    print("=" * 70)

def print_success(text: str):
    """Print success message"""
    print(colored(f"✓ {text}", Colors.GREEN))

def print_error(text: str):
    """Print error message"""
    print(colored(f"✗ {text}", Colors.RED))

def print_warning(text: str):
    """Print warning message"""
    print(colored(f"⚠ {text}", Colors.YELLOW))

def run_test_file(test_path: Path, verbose: bool = False) -> Tuple[bool, float, Optional[str]]:
    """
    Run a single test file and return (success, duration, error_output)
    """
    start_time = time.time()

    try:
        result = subprocess.run(
            [sys.executable, str(test_path)],
            capture_output=True,
            text=True,
            timeout=30,
            cwd=test_path.parent.parent
        )
        duration = time.time() - start_time

        if result.returncode == 0:
            return True, duration, None
        else:
            error_msg = result.stderr if result.stderr else result.stdout
            return False, duration, error_msg

    except subprocess.TimeoutExpired:
        duration = time.time() - start_time
        return False, duration, "Test timed out after 30 seconds"

    except Exception as e:
        duration = time.time() - start_time
        return False, duration, str(e)

def get_test_files(tests_dir: Path, category: Optional[str] = None) -> List[Path]:
    """
    Get list of test files to run based on category filter
    """
    all_tests = sorted(tests_dir.glob("test_*.py"))

    if category is None:
        return all_tests

    category_filters = {
        'features': ['test_new_features.py', 'test_combined.py', 'test_design_example.py'],
        'repl': ['test_repl.py', 'test_repl_functions.py', 'test_repl_comprehensive.py'],
        'pipeline': ['test_pipeline_debug.py'],
        'performance': ['test_performance.py'],
    }

    if category not in category_filters:
        print_warning(f"Unknown category: {category}")
        return all_tests

    return [t for t in all_tests if t.name in category_filters[category]]

def main():
    parser = argparse.ArgumentParser(
        description='Run Sol language tests',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Categories:
  features     - New feature tests (Result types, pipelines, f-strings)
  repl         - REPL functionality tests
  pipeline     - Pipeline operator debug tests
  performance  - Performance benchmarks

Examples:
  python run_tests.py              # Run all tests
  python run_tests.py features     # Run feature tests only
  python run_tests.py -v           # Verbose mode
        """
    )

    parser.add_argument(
        'category',
        nargs='?',
        help='Test category to run (features, repl, pipeline, performance)'
    )

    parser.add_argument(
        '-v', '--verbose',
        action='store_true',
        help='Show detailed test output'
    )

    parser.add_argument(
        '-f', '--fail-fast',
        action='store_true',
        help='Stop on first failure'
    )

    args = parser.parse_args()

    # Get tests directory
    tests_dir = Path(__file__).parent / 'tests'

    if not tests_dir.exists():
        print_error("Tests directory not found!")
        sys.exit(1)

    # Get test files
    test_files = get_test_files(tests_dir, args.category)

    if not test_files:
        print_warning("No test files found!")
        sys.exit(1)

    # Print header
    category_name = args.category.upper() if args.category else "ALL"
    print_header(f"Sol Test Suite - {category_name} TESTS")
    print(f"Found {len(test_files)} test file(s)")
    print()

    # Run tests
    results = []
    failed_tests = []

    for test_file in test_files:
        test_name = test_file.stem.replace('test_', '').replace('_', ' ').title()
        print(f"Running: {colored(test_name, Colors.BOLD)} ", end='', flush=True)

        success, duration, error = run_test_file(test_file, args.verbose)
        results.append((test_name, success, duration, error))

        if success:
            print_success(f"PASSED ({duration:.2f}s)")
            if args.verbose and test_file.name != 'test_performance.py':
                # Show output in verbose mode
                result = subprocess.run(
                    [sys.executable, str(test_file)],
                    capture_output=True,
                    text=True,
                    cwd=test_file.parent.parent
                )
                if result.stdout:
                    print(result.stdout)
        else:
            print_error(f"FAILED ({duration:.2f}s)")
            failed_tests.append((test_name, error))

            if error and not args.verbose:
                # Show first few lines of error
                error_lines = error.split('\n')[:5]
                for line in error_lines:
                    print(f"  {line}")
                if len(error.split('\n')) > 5:
                    print(f"  ... (use -v for full output)")
            elif error and args.verbose:
                print(error)

            if args.fail_fast:
                print_warning("\nStopping on first failure (--fail-fast)")
                break

    # Print summary
    print_header("TEST SUMMARY")

    passed = sum(1 for _, success, _, _ in results if success)
    failed = len(results) - passed
    total_duration = sum(duration for _, _, duration, _ in results)

    print(f"Total tests: {len(results)}")
    print_success(f"Passed: {passed}")

    if failed > 0:
        print_error(f"Failed: {failed}")
        print()
        print(colored("Failed tests:", Colors.BOLD))
        for test_name, error in failed_tests:
            print(f"  • {test_name}")

    print(f"\nTotal time: {total_duration:.2f}s")

    print("=" * 70)

    # Exit with appropriate code
    if failed > 0:
        print()
        print_error("Some tests failed!")
        sys.exit(1)
    else:
        print()
        print_success("All tests passed! 🎉")
        sys.exit(0)

if __name__ == "__main__":
    main()
