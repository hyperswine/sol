# Sol — Enhanced Features Demo
# Demonstrates pipelines, guards, and infix operators

# === Basic Pipes ===
echo "=== Basic Pipelines ===".

# Array operations with named helpers
double x = x * 2.
nums = [1, 2, 3, 4, 5].
doubled = nums |> map double.
echo "Doubled: {doubled}".

# Filter with a named predicate
gtFive x = x > 5.
filtered = doubled |> filter gtFive.
echo "Filtered (> 5): {filtered}".

# Complete chain with fold
addUp a b = a + b.
total = nums |> map double |> filter gtFive |> fold addUp 0.
echo "Sum of doubled filtered: {total}".

# === Guarded definitions ===
echo "=== Guarded Definitions ===".

# Value guard (0-param)
flag = 1.
status | flag = "enabled".
status        = "disabled".
echo "Status: {status}".

# Function guard
classify x | x > 100 = "large".
classify x | x > 0   = "positive".
classify x            = "non-positive".

r150 = classify 150.
r42  = classify 42.
rn5  = classify -5.
echo "classify 150: {r150}".
echo "classify 42:  {r42}".
echo "classify -5:  {rn5}".

# === Complex Combinations ===
echo "=== Complex Operations ===".

data = [10, 20, 30, 40].
sumDoubled = data |> map double |> fold addUp 0.
echo "Sum of doubled data: {sumDoubled}".

# Multiple conditions via guards
score = 85.
grade | score > 90 = "A".
grade | score > 80 = "B".
grade | score > 70 = "C".
grade              = "D".
echo "Score {score} gets grade: {grade}".

temp = 75.
weather | temp > 80 = "hot".
weather | temp > 60 = "nice".
weather             = "cold".
echo "Temperature {temp} feels: {weather}".

echo "=== All tests complete! ===".
