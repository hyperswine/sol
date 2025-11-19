#!/usr/bin/env python3
"""
Test the combined features with simpler examples
"""

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent))

from parsing import create_parser
from interpret import create_interpreter
import os

# Set some env vars for testing
os.environ['VERSION'] = 'v2.0.0'
os.environ['REGISTRY'] = 'docker.io'

parser = create_parser()
interpreter = create_interpreter()

print("=" * 60)
print("Testing Combined Features with Env Vars Set")
print("=" * 60)

code = '''
version = getenv "VERSION" |> unwrap_or "latest".
registry = getenv "REGISTRY" |> unwrap_or "registry.io".
service = "myapp".
echo "Deploying {service}:{version} to {registry}".
'''

print(f"\nCode:\n{code}")
print("\nOutput:")
parsed = parser.parse(code)
interpreter.run(parsed)

print("\n" + "=" * 60)
print("Testing with Missing Env Vars")
print("=" * 60)

# Unset the env vars
os.environ.pop('VERSION', None)
os.environ.pop('REGISTRY', None)

interpreter2 = create_interpreter()
parsed2 = parser.parse(code)
print("\nOutput:")
interpreter2.run(parsed2)
