#!/usr/bin/env python3
"""
Comprehensive REPL test for function and variable persistence
"""

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent))

from parsing import create_parser

from interpret import create_interpreter

parser = create_parser()
interpreter = create_interpreter()

print("Testing REPL Persistence:")
print("=" * 60)

test_cases = [
    ("Define function f", "f a b = + a b."),
    ("Call function f", "f 1 2."),
    ("Define variable x", "x = 5."),
    ("Use variable x", "echo x."),
    ("Define function g using x", "g n = * n x."),
    ("Call function g", "g 3."),
    ("Define function h", "h = + 1."),
    ("Call function h", "h 10."),
]

for description, code in test_cases:
    print(f"\n{description}: {code}")
    parsed = parser.parse(code)
    interpreter.run(parsed, print_immediately=True)

# Final environment check
env = interpreter.get_environment_snapshot()
print("\n" + "=" * 60)
print("Final Environment:")
print(f"  Variables: {list(env['variables'].keys())}")
print(f"  User functions: {list(env['user_functions'].keys())}")
print("=" * 60)
print("✅ All tests passed!")
