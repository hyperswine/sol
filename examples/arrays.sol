# Test array functionality
myarray = [1, 2, 3].
echo "Array:".
echo myarray.

# Test apostrophe in identifiers
res' = 42.
echo "Result with apostrophe:".
echo res'.

# Test nested arrays
nested = [[1, 2], [3, 4]].
echo "Nested array:".
echo nested.

# Fibonacci using guards instead of if/then/else
fib n | n == 0 = 0.
fib n | n == 1 = 1.
fib n          = fib (n - 1) + fib (n - 2).
echo (fib 10).    # → 55
