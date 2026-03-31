# Sol 1.0 - Enhanced Features Demo
# Demonstrates working pipes and if expressions

# === Basic Pipes ===
echo "=== Basic Pipelines ===".

# Simple value transformation
x1 = 5 |> + 10.
echo "5 |> + 10 = {x1}".

# Array operations
nums = [1, 2, 3, 4, 5].
doubled = nums |> map (* 2).
echo "Doubled: {doubled}".

# Chained operations
filtered = doubled |> filter (> 5).
echo "Filtered (> 5): {filtered}".

# Complete chain with fold
sum = nums |> map (* 2) |> filter (> 5) |> fold + 0.
echo "Sum of doubled filtered: {sum}".

# === If Expressions ===
echo "=== If Expressions ===".

# With literal condition
result1 = if 1 then "truthy" else "falsy".
echo "if 1: {result1}".

result2 = if 0 then "truthy" else "falsy".
echo "if 0: {result2}".

# With variable condition
flag = 1.
status = if flag then "enabled" else "disabled".
echo "Status: {status}".

# With comparison
age = 25.
category = if (> age 18) then "adult" else "minor".
echo "Age {age} is {category}".

# With string conditions
name = "Alice".
greeting = if name then "Hello {name}" else "Hello stranger".
echo "{greeting}".

# With empty string (falsy)
empty = "".
msg = if empty then "has content" else "empty".
echo "Empty string test: {msg}".

# === Complex Combinations ===
echo "=== Complex Operations ===".

# Variable in pipeline
data = [10, 20, 30, 40].
avg_doubled = data |> map (* 2) |> fold + 0.
echo "Sum of doubled data: {avg_doubled}".

# If expression choosing between values (use literal to avoid parser issue)
x = 100.
choice = if (> x 50) then 100 else 0.
echo "Choice based on x>50: {choice}".

# Multiple conditions
score = 85.
grade = if (> score 90) then "A" else if (> score 80) then "B" else "C".
echo "Score {score} gets grade: {grade}".

# Nested if expressions
temp = 75.
weather = if (> temp 80) then "hot" else if (> temp 60) then "nice" else "cold".
echo "Temperature {temp} feels: {weather}".

echo "=== All tests complete! ===".
