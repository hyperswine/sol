#!/usr/bin/env python3
"""
Generate API documentation from stdlib modules.
"""
import inspect
from pathlib import Path


def extract_function_doc(func):
    """Extract docstring information from a function."""
    doc = inspect.getdoc(func)
    if not doc:
        return None

    # Parse docstring sections
    lines = doc.split('\n')
    brief = lines[0] if lines else ""

    return {
        'name': func.__name__,
        'brief': brief,
        'full_doc': doc
    }


def generate_module_docs(module_name):
    """Generate documentation for a stdlib module."""
    try:
        import importlib
        module = importlib.import_module(f"stdlib.{module_name}")

        print(f"\n## {module_name.title()} Module\n")
        print(f"**File:** `stdlib/{module_name}.py`\n")        # Get module docstring
        if module.__doc__:
            print(module.__doc__.strip())
            print()

        # Get all functions
        functions = []
        for name in dir(module):
            obj = getattr(module, name)
            if callable(obj) and not name.startswith('_'):
                doc_info = extract_function_doc(obj)
                if doc_info:
                    functions.append(doc_info)

        # Print function summaries
        if functions:
            print("### Functions\n")
            for func_info in functions:
                print(f"#### `{func_info['name']}`")
                print(f"{func_info['brief']}\n")
                print("```python")
                print(func_info['full_doc'])
                print("```\n")

    except Exception as e:
        print(f"Error loading {module_name}: {e}")


def main():
    """Generate complete API documentation."""
    print("# Sol Standard Library API Reference\n")
    print("Complete documentation for all stdlib functions.\n")
    print("Generated from module docstrings.\n")

    modules = [
        'filesystem',
        'network',
        'git',
        'data',
        'system',
        'hashing',
        'operators',
        'conversion'
    ]

    for module in modules:
        generate_module_docs(module)


if __name__ == "__main__":
    main()
