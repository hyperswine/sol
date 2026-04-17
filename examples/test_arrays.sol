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

fib n = if == n 0 then 0 else if == n 1 then 1 else (+ (fib (- n 1)) (fib (- n 2))).
echo (fib 10).    # → 55
