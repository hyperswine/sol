# Test progress functionality

echo "=== Testing Progress Bar ===".

# Test 1: Simple value with progress (shows quick animation)
echo "Test 1: Simple value".
x = progress 42.
echo "Result: {x}".
echo "".

# Test 2: Progress with network operation
echo "Test 2: Network download with progress".
# Note: Use wget with True to enable progress
# content = wget "https://api.github.com/zen" 1.
# For now, demonstrate with simple operation
data = progress (+ 10 20).
echo "Result: {data}".
echo "".

# Test 3: Multiple operations
echo "Test 3: Multiple operations".
nums = [1, 2, 3, 4, 5].
result = progress (fold + 0 nums).
echo "Sum: {result}".
echo "".

echo "=== All Progress Tests Complete ===".
