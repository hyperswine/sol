"""
Performance test for optimized Sol interpreter
"""
import time
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent))

from interpret import Environment, create_interpreter, get_cache_info, clear_caches
from parsing import create_parser



def test_environment_performance():
  """Test environment operations with pyrsistent"""
  print("=== Environment Performance Test ===\n")

  # Test 1: Variable creation and lookup
  start = time.perf_counter()
  env = Environment()
  for i in range(1000):
    env = env.with_variable(f"var_{i}", i)

  # Lookup all variables
  for i in range(1000):
    _ = env.get_variable(f"var_{i}")

  end = time.perf_counter()
  print(f"  Created and accessed 1000 variables: {(end-start)*1000:.2f}ms")
  print(f"  (Using pyrsistent PMap with O(log n) operations)")

  # Test 2: Function definitions
  start = time.perf_counter()
  for i in range(100):
    env = env.with_function(f"func_{i}", ["x", "y"], ["+", "x", "y"])

  for i in range(100):
    _ = env.get_function(f"func_{i}")

  end = time.perf_counter()
  print(f"  Created and accessed 100 functions: {(end-start)*1000:.2f}ms\n")


def test_cache_performance():
  """Test LRU cache effectiveness"""
  print("=== Cache Performance Test ===\n")

  clear_caches()
  parser = create_parser()
  interpreter = create_interpreter()

  # Test parsing numbers repeatedly
  test_code = """
x = 42.
y = 123.
z = 3.14.
a = 42.
b = 123.
c = 3.14.
"""

  start = time.perf_counter()
  for _ in range(100):
    parsed = parser.parse(test_code)
    if not isinstance(parsed, str):  # Skip if parse error
      interpreter.run(parsed, print_immediately=False)

  end = time.perf_counter()

  cache_info = get_cache_info()
  print(f"  Parsed and executed code 100 times: {(end-start)*1000:.2f}ms")
  print(f"  Cache stats for _parse_number:")
  print(f"    - Hits: {cache_info['_parse_number']['hits']}")
  print(f"    - Misses: {cache_info['_parse_number']['misses']}")
  print(
      f"    - Hit rate: {cache_info['_parse_number']['hits'] / max(1, cache_info['_parse_number']['hits'] + cache_info['_parse_number']['misses']) * 100:.1f}%")
  print(
      f"    - Cache size: {cache_info['_parse_number']['currsize']}/{cache_info['_parse_number']['maxsize']}\n")


def test_structural_sharing():
  """Demonstrate structural sharing benefits"""
  print("=== Structural Sharing Benefits ===\n")

  env1 = Environment()
  env1 = env1.with_variable("a", 1)
  env1 = env1.with_variable("b", 2)

  # Creating new environment shares structure with env1
  env2 = env1.with_variable("c", 3)
  env3 = env2.with_variable("d", 4)

  print(f"  env1 has variables: {list(env1.variables.keys())}")
  print(
      f"  env2 shares env1's structure + new var: {list(env2.variables.keys())}")
  print(
      f"  env3 shares env2's structure + new var: {list(env3.variables.keys())}")
  print(f"  (Structural sharing means minimal memory copying)\n")


if __name__ == "__main__":
  print("Sol Interpreter - Performance Optimizations")
  print("=" * 50)
  print("Using pyrsistent for efficient immutable data structures")
  print("Using functools.lru_cache for memoization")
  print("=" * 50)
  print()

  test_environment_performance()
  test_cache_performance()
  test_structural_sharing()

  print("=" * 50)
  print("All performance tests completed!")
