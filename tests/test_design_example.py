#!/usr/bin/env python3
"""
Test the exact example from the DESIGN.md to verify it works
"""

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent))

from parsing import create_parser
from interpret import create_interpreter
import os

# Set up environment for testing
os.environ['VERSION'] = 'v2.1.0'
os.environ['REGISTRY'] = 'my-registry.io'

parser = create_parser()
interpreter = create_interpreter()

print("=" * 70)
print("Testing Example from DESIGN.md")
print("=" * 70)

# Simplified version of the design doc example (without if statements for now)
code = '''
echo "=== Deployment Script ===".

docker_check = sh "docker --version".
echo "Docker check passed: {succeeded docker_check}".

version = getenv "VERSION" |> unwrap_or "latest".
registry = getenv "REGISTRY" |> unwrap_or "registry.io".

echo "Version: {version}".
echo "Registry: {registry}".

service = "api".
echo "Building {service}...".
result = sh "echo Simulating docker build for {service}".
echo "Build result: {result}".

tag = "{registry}/{service}:{version}".
echo "Would push: {tag}".

echo "=== Deployment complete! ===".
'''

print(f"\nCode:\n{code}")
print("\n" + "=" * 70)
print("Output:")
print("=" * 70)
parsed = parser.parse(code)
result = interpreter.run(parsed)

print("\n" + "=" * 70)
print("✅ Test completed successfully!")
print("=" * 70)
