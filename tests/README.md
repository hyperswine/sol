# Sol Test Suite

This directory contains all tests for the Sol scripting language.

## Test Organization

### Feature Tests
- **test_new_features.py** - Comprehensive tests for new features (Result types, pipelines, f-strings)
- **test_combined.py** - Combined feature tests with environment variables
- **test_design_example.py** - Tests based on examples from DESIGN.md

### REPL Tests
- **test_repl.py** - Basic REPL functionality tests
- **test_repl_functions.py** - Tests for function definition persistence in REPL
- **test_repl_comprehensive.py** - Comprehensive REPL state persistence tests

### Debug Tests
- **test_pipeline_debug.py** - Pipeline operator parsing and execution debugging

### Performance Tests
- **test_performance.py** - Performance benchmarks and profiling

## Running Tests

### Quick Start

Run all tests:
```bash
python run_tests.py
```

### Run by Category

Run specific test categories:
```bash
python run_tests.py features     # New feature tests
python run_tests.py repl         # REPL tests
python run_tests.py performance  # Performance tests
```

### Options

```bash
python run_tests.py -v           # Verbose mode (show full output)
python run_tests.py -f           # Fail fast (stop on first failure)
python run_tests.py features -v  # Verbose feature tests
```

### Individual Tests

Run a single test file:
```bash
.venv/bin/python tests/test_new_features.py
```

## Writing New Tests

When adding new tests:

1. Create a test file with `test_` prefix (e.g., `test_myfeature.py`)
2. Import required modules:
   ```python
   from parsing import create_parser
   from interpret import create_interpreter
   ```
3. Structure tests with clear descriptions
4. Include success/failure indicators
5. Update this README if adding a new category

### Test Template

```python
#!/usr/bin/env python3
"""
Test description
"""

from parsing import create_parser
from interpret import create_interpreter

def test_my_feature():
    """Test specific functionality"""
    parser = create_parser()
    interpreter = create_interpreter()

    code = '''
    # Sol code here
    x = 42.
    echo x.
    '''

    print("Testing my feature...")
    parsed = parser.parse(code)
    interpreter.run(parsed)
    print("✅ Test passed!")

if __name__ == "__main__":
    try:
        test_my_feature()
        print("\n✅ All tests completed!")
    except Exception as e:
        print(f"\n❌ Test failed: {e}")
        import traceback
        traceback.print_exc()
        exit(1)
```

## Test Coverage

Current test coverage includes:

- ✅ Result types (`unwrap_or`, `unwrap_or_exit`, `failed`, `succeeded`)
- ✅ Pipeline operator (`|>`)
- ✅ F-string interpolation
- ✅ REPL function persistence
- ✅ REPL variable persistence
- ✅ Combined feature usage
- ✅ Basic language features

## Continuous Integration

Tests can be integrated into CI/CD pipelines:

```yaml
# Example GitHub Actions workflow
- name: Run tests
  run: |
    python -m venv .venv
    source .venv/bin/activate
    pip install -r requirements.txt
    python run_tests.py
```

## Troubleshooting

If tests fail:

1. Check that all dependencies are installed: `pip install -r requirements.txt`
2. Ensure you're using the virtual environment: `source .venv/bin/activate`
3. Run tests in verbose mode: `python run_tests.py -v`
4. Run individual failing tests to see full output
5. Check the main project README for setup instructions

## Performance Testing

Performance tests measure:
- Parsing speed
- Interpretation speed
- Memory usage
- Cache effectiveness

Run performance tests separately as they may take longer:
```bash
python run_tests.py performance
```
