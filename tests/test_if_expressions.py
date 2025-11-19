"""
Test if expressions in Sol
"""
import sys
import os

# Add parent directory to path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from parsing import create_parser
from interpret import create_interpreter


def test_simple_if_true():
  """Test basic if expression with true condition"""
  parser = create_parser()
  interpreter = create_interpreter()

  # Simple true condition
  code = 'x = if 1 then "yes" else "no".'
  parsed = parser.parse(code)
  assert not isinstance(parsed, str), f"Parse error: {parsed}"

  interpreter.run(parsed)
  assert interpreter.environment.get_variable('x') == 'yes', \
    f"Expected 'yes', got {interpreter.environment.get_variable('x')}"
  print("✓ Simple if with true condition works")


def test_simple_if_false():
  """Test basic if expression with false condition"""
  parser = create_parser()
  interpreter = create_interpreter()

  # Simple false condition
  code = 'x = if 0 then "yes" else "no".'
  parsed = parser.parse(code)
  assert not isinstance(parsed, str), f"Parse error: {parsed}"

  interpreter.run(parsed)
  assert interpreter.environment.get_variable('x') == 'no', \
    f"Expected 'no', got {interpreter.environment.get_variable('x')}"
  print("✓ Simple if with false condition works")


def test_if_with_comparison():
  """Test if expression with comparison function"""
  parser = create_parser()
  interpreter = create_interpreter()

  # Set up variable and compare
  code = '''
x = 5.
y = if (> 3 x) then "big" else "small".
'''
  parsed = parser.parse(code)
  assert not isinstance(parsed, str), f"Parse error: {parsed}"

  interpreter.run(parsed)
  assert interpreter.environment.get_variable('y') == 'big', \
    f"Expected 'big', got {interpreter.environment.get_variable('y')}"
  print("✓ If with comparison function works")


def test_if_with_variable_condition():
  """Test if expression with variable as condition"""
  parser = create_parser()
  interpreter = create_interpreter()

  code = '''
flag = 1.
result = if flag then "on" else "off".
'''
  parsed = parser.parse(code)
  assert not isinstance(parsed, str), f"Parse error: {parsed}"

  interpreter.run(parsed)
  assert interpreter.environment.get_variable('result') == 'on', \
    f"Expected 'on', got {interpreter.environment.get_variable('result')}"
  print("✓ If with variable condition works")


def test_if_with_pipeline():
  """Test if expression in pipeline"""
  parser = create_parser()
  interpreter = create_interpreter()

  code = '''
x = 10.
result = if (> 5 x) then x else 0 |> + 100.
'''
  parsed = parser.parse(code)
  assert not isinstance(parsed, str), f"Parse error: {parsed}"

  interpreter.run(parsed)
  value = interpreter.environment.get_variable('result')
  assert value == 110, f"Expected 110 (10 + 100), got {value}"
  print("✓ If expression in pipeline works")


def test_if_with_numeric_branches():
  """Test if expression with numeric then/else branches"""
  parser = create_parser()
  interpreter = create_interpreter()

  code = '''
x = 1.
y = if x then (+ x 2) else (+ x 4).
'''
  parsed = parser.parse(code)
  assert not isinstance(parsed, str), f"Parse error: {parsed}"

  interpreter.run(parsed)
  value = interpreter.environment.get_variable('y')
  assert value == 3, f"Expected 3 (1 + 2), got {value}"
  print("✓ If with numeric expressions in branches works")


def test_if_with_string_condition():
  """Test if expression with string condition (truthy/falsy)"""
  parser = create_parser()
  interpreter = create_interpreter()

  # Non-empty string is truthy
  code = '''
name = "Alice".
greeting = if name then "Hello" else "Goodbye".
'''
  parsed = parser.parse(code)
  assert not isinstance(parsed, str), f"Parse error: {parsed}"

  interpreter.run(parsed)
  assert interpreter.environment.get_variable('greeting') == 'Hello', \
    f"Expected 'Hello', got {interpreter.environment.get_variable('greeting')}"
  print("✓ If with truthy string works")


def test_if_with_empty_string():
  """Test if expression with empty string (falsy)"""
  parser = create_parser()
  interpreter = create_interpreter()

  code = '''
name = "".
greeting = if name then "Hello" else "Goodbye".
'''
  parsed = parser.parse(code)
  assert not isinstance(parsed, str), f"Parse error: {parsed}"

  interpreter.run(parsed)
  assert interpreter.environment.get_variable('greeting') == 'Goodbye', \
    f"Expected 'Goodbye', got {interpreter.environment.get_variable('greeting')}"
  print("✓ If with falsy empty string works")


def test_if_with_array_condition():
  """Test if expression with array condition"""
  parser = create_parser()
  interpreter = create_interpreter()

  # Non-empty array is truthy
  code = '''
items = [1, 2, 3].
status = if items then "has items" else "empty".
'''
  parsed = parser.parse(code)
  assert not isinstance(parsed, str), f"Parse error: {parsed}"

  interpreter.run(parsed)
  assert interpreter.environment.get_variable('status') == 'has items', \
    f"Expected 'has items', got {interpreter.environment.get_variable('status')}"
  print("✓ If with truthy array works")


def test_if_standalone_statement():
  """Test if expression as standalone statement"""
  parser = create_parser()
  interpreter = create_interpreter()

  code = '''
x = 1.
if x then echo "true" else echo "false".
'''
  parsed = parser.parse(code)
  assert not isinstance(parsed, str), f"Parse error: {parsed}"

  # Should execute without error
  interpreter.run(parsed)
  print("✓ Standalone if statement works")


def test_nested_if():
  """Test nested if expressions"""
  parser = create_parser()
  interpreter = create_interpreter()

  code = '''
x = 5.
result = if (> 10 x) then "very big" else if (> 5 x) then "big" else "small".
'''
  parsed = parser.parse(code)
  assert not isinstance(parsed, str), f"Parse error: {parsed}"

  interpreter.run(parsed)
  value = interpreter.environment.get_variable('result')
  assert value == 'small', f"Expected 'small', got {value}"
  print("✓ Nested if expressions work")


def test_if_with_fstring():
  """Test if expression with f-string interpolation"""
  parser = create_parser()
  interpreter = create_interpreter()

  code = '''
x = 10.
msg = if (> 5 x) then "x is {x}" else "x is small".
'''
  parsed = parser.parse(code)
  assert not isinstance(parsed, str), f"Parse error: {parsed}"

  interpreter.run(parsed)
  value = interpreter.environment.get_variable('msg')
  assert value == 'x is 10', f"Expected 'x is 10', got {value}"
  print("✓ If expression with f-string works")

def run_all_tests():
  """Run all if expression tests"""
  print("\n=== Testing If Expressions ===\n")

  tests = [
    test_simple_if_true,
    test_simple_if_false,
    test_if_with_comparison,
    test_if_with_variable_condition,
    test_if_with_pipeline,
    test_if_with_numeric_branches,
    test_if_with_string_condition,
    test_if_with_empty_string,
    test_if_with_array_condition,
    test_if_standalone_statement,
    test_nested_if,
    test_if_with_fstring,
  ]

  failed = 0
  for test in tests:
    try:
      test()
    except Exception as e:
      print(f"✗ {test.__name__} failed: {e}")
      failed += 1

  print(f"\n{len(tests) - failed}/{len(tests)} tests passed")
  return failed == 0


if __name__ == "__main__":
  success = run_all_tests()
  sys.exit(0 if success else 1)
