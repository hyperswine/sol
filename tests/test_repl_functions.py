#!/usr/bin/env python3
"""
Test REPL function definition bug
"""

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent))

from parsing import create_parser

from interpret import create_interpreter

parser = create_parser()
interpreter = create_interpreter()

print("Testing REPL function definition persistence:")
print("=" * 60)

# Step 1: Define function
print("\n1. Defining function: f a b = + a b.")
code1 = "f a b = + a b."
parsed1 = parser.parse(code1)
result1, vars1 = interpreter.run(parsed1, print_immediately=True)

# Check environment
env_snapshot = interpreter.get_environment_snapshot()
print(f"\nEnvironment after definition:")
print(f"  User functions: {list(env_snapshot['user_functions'].keys())}")

# Step 2: Call function
print("\n2. Calling function: f 1 2.")
code2 = "f 1 2."
parsed2 = parser.parse(code2)
result2, vars2 = interpreter.run(parsed2, print_immediately=True)

# Check environment again
env_snapshot2 = interpreter.get_environment_snapshot()
print(f"\nEnvironment after call:")
print(f"  User functions: {list(env_snapshot2['user_functions'].keys())}")

print("\n" + "=" * 60)
print("✅ Test complete - function should have been called successfully!")
