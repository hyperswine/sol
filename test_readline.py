#!/usr/bin/env python3
"""
Test readline tab completion
"""
import readline

def test_completer(text, state):
    """Simple test completer"""
    options = ['ls', 'echo', 'read', 'write', 'map', 'filter']
    matches = [opt for opt in options if opt.startswith(text)]

    if state < len(matches):
        return matches[state]
    return None

# Set up readline
readline.parse_and_bind('tab: complete')
readline.set_completer(test_completer)
readline.set_completer_delims(' \t\n')

print("Test tab completion:")
print("Type 'l' and press TAB - should show 'ls'")
print("Type 'e' and press TAB - should show 'echo'")
print()

try:
    line = input("test> ")
    print(f"You entered: {line}")
except (EOFError, KeyboardInterrupt):
    print("\nDone")
