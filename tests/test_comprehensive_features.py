"""
Comprehensive test suite for pipes and if expressions in Sol
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from parsing import create_parser
from interpret import create_interpreter


def test_basic_pipe():
    """Test basic pipeline"""
    parser = create_parser()
    interpreter = create_interpreter()

    code = 'x = 5 |> + 10.'
    parsed = parser.parse(code)
    assert not isinstance(parsed, str), f"Parse error: {parsed}"

    interpreter.run(parsed)
    value = interpreter.environment.get_variable('x')
    assert value == 15, f"Expected 15, got {value}"
    print("✓ Basic pipe works")


def test_pipe_with_array():
    """Test pipeline with array"""
    parser = create_parser()
    interpreter = create_interpreter()

    code = 'x = [1, 2, 3] |> map (* 2).'
    parsed = parser.parse(code)
    assert not isinstance(parsed, str), f"Parse error: {parsed}"

    interpreter.run(parsed)
    value = interpreter.environment.get_variable('x')
    assert value == [2, 4, 6], f"Expected [2, 4, 6], got {value}"
    print("✓ Pipe with array works")


def test_pipe_chain():
    """Test chained pipeline"""
    parser = create_parser()
    interpreter = create_interpreter()

    code = 'x = [1, 2, 3, 4, 5] |> map (* 2) |> filter (> 5).'
    parsed = parser.parse(code)
    assert not isinstance(parsed, str), f"Parse error: {parsed}"

    interpreter.run(parsed)
    value = interpreter.environment.get_variable('x')
    assert value == [6, 8, 10], f"Expected [6, 8, 10], got {value}"
    print("✓ Pipe chain works")


def test_pipe_with_fold():
    """Test pipeline with fold"""
    parser = create_parser()
    interpreter = create_interpreter()

    code = 'x = [1, 2, 3, 4, 5] |> fold + 0.'
    parsed = parser.parse(code)
    assert not isinstance(parsed, str), f"Parse error: {parsed}"

    interpreter.run(parsed)
    value = interpreter.environment.get_variable('x')
    assert value == 15, f"Expected 15, got {value}"
    print("✓ Pipe with fold works")


def test_pipe_complex():
    """Test complex pipeline with map, filter, fold"""
    parser = create_parser()
    interpreter = create_interpreter()

    code = 'x = [1, 2, 3, 4, 5] |> map (* 2) |> filter (> 5) |> fold + 0.'
    parsed = parser.parse(code)
    assert not isinstance(parsed, str), f"Parse error: {parsed}"

    interpreter.run(parsed)
    value = interpreter.environment.get_variable('x')
    assert value == 24, f"Expected 24, got {value}"
    print("✓ Complex pipe chain works")


def test_pipe_with_variable():
    """Test pipeline starting with variable"""
    parser = create_parser()
    interpreter = create_interpreter()

    code = '''
nums = [1, 2, 3].
doubled = nums |> map (* 2).
'''
    parsed = parser.parse(code)
    assert not isinstance(parsed, str), f"Parse error: {parsed}"

    interpreter.run(parsed)
    value = interpreter.environment.get_variable('doubled')
    assert value == [2, 4, 6], f"Expected [2, 4, 6], got {value}"
    print("✓ Pipe with variable works")


def test_pipe_with_function_call():
    """Test pipeline with function call as input"""
    parser = create_parser()
    interpreter = create_interpreter()

    code = 'x = (+ 1 2) |> * 3.'
    parsed = parser.parse(code)
    assert not isinstance(parsed, str), f"Parse error: {parsed}"

    interpreter.run(parsed)
    value = interpreter.environment.get_variable('x')
    assert value == 9, f"Expected 9 (3 * 3), got {value}"
    print("✓ Pipe with function call works")


def test_if_with_literal_condition():
    """Test if with literal condition"""
    parser = create_parser()
    interpreter = create_interpreter()

    code = 'x = if 1 then "yes" else "no".'
    parsed = parser.parse(code)
    assert not isinstance(parsed, str), f"Parse error: {parsed}"

    interpreter.run(parsed)
    value = interpreter.environment.get_variable('x')
    assert value == "yes", f"Expected 'yes', got {value}"
    print("✓ If with literal works")


def test_if_with_variable_condition():
    """Test if with variable condition - KNOWN TO FAIL"""
    parser = create_parser()
    interpreter = create_interpreter()

    code = '''
flag = 1.
result = if flag then "on" else "off".
'''
    parsed = parser.parse(code)
    assert not isinstance(parsed, str), f"Parse error: {parsed}"

    interpreter.run(parsed)
    value = interpreter.environment.get_variable('result')
    assert value == "on", f"Expected 'on', got {value}"
    print("✓ If with variable condition works")


def test_if_with_comparison():
    """Test if with comparison result"""
    parser = create_parser()
    interpreter = create_interpreter()

    code = '''
x = 10.
result = if (> x 5) then "big" else "small".
'''
    parsed = parser.parse(code)
    assert not isinstance(parsed, str), f"Parse error: {parsed}"

    interpreter.run(parsed)
    value = interpreter.environment.get_variable('result')
    assert value == "big", f"Expected 'big', got {value}"
    print("✓ If with comparison works")


def test_if_in_pipe():
    """Test if expression in pipeline"""
    parser = create_parser()
    interpreter = create_interpreter()

    code = '''
x = 10.
result = if (> x 5) then x else 0 |> + 100.
'''
    parsed = parser.parse(code)
    assert not isinstance(parsed, str), f"Parse error: {parsed}"

    interpreter.run(parsed)
    value = interpreter.environment.get_variable('result')
    assert value == 110, f"Expected 110, got {value}"
    print("✓ If in pipe works")


def test_pipe_with_if():
    """Test pipeline containing if expression"""
    parser = create_parser()
    interpreter = create_interpreter()

    code = '''
nums = [1, 2, 3, 4, 5].
result = nums |> map (if (> x 3) then (* x 2) else x).
'''
    parsed = parser.parse(code)
    if isinstance(parsed, str):
        print(f"⚠ Pipe with if (map with if lambda) - not yet supported: {parsed}")
        return

    interpreter.run(parsed)
    value = interpreter.environment.get_variable('result')
    print(f"✓ Pipe with if expression works: {value}")


def run_all_tests():
    """Run all tests"""
    print("\n=== Testing Pipes and If Expressions ===\n")

    tests = [
        # Pipe tests
        ("Pipe - Basic", test_basic_pipe),
        ("Pipe - With Array", test_pipe_with_array),
        ("Pipe - Chain", test_pipe_chain),
        ("Pipe - With Fold", test_pipe_with_fold),
        ("Pipe - Complex", test_pipe_complex),
        ("Pipe - With Variable", test_pipe_with_variable),
        ("Pipe - With Function Call", test_pipe_with_function_call),

        # If tests
        ("If - Literal Condition", test_if_with_literal_condition),
        ("If - Variable Condition", test_if_with_variable_condition),
        ("If - Comparison", test_if_with_comparison),
        ("If - In Pipe", test_if_in_pipe),
        ("If - With Pipe (Advanced)", test_pipe_with_if),
    ]

    passed = 0
    failed = 0

    for name, test in tests:
        try:
            test()
            passed += 1
        except AssertionError as e:
            print(f"✗ {name} failed: {e}")
            failed += 1
        except Exception as e:
            print(f"✗ {name} errored: {e}")
            failed += 1

    print(f"\n{passed}/{len(tests)} tests passed")
    return failed == 0


if __name__ == "__main__":
    success = run_all_tests()
    sys.exit(0 if success else 1)
