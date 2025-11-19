#!/usr/bin/env python3
"""
Simple test for pipeline debugging
"""

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent))

from parsing import create_parser

from interpret import create_interpreter

parser = create_parser()
interpreter = create_interpreter()

# Test pipeline with unwrap_or
code = '''
version = getenv "MISSING" |> unwrap_or "latest".
echo version.
'''

print("Testing pipeline:")
print(code)
print("\nParsing...")
parsed = parser.parse(code)
print(f"Parsed: {parsed}")
print("\nRunning...")
interpreter.run(parsed)
