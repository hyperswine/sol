# Sol Feature Showcase: pipeline operator, f-string interpolation, guards, infix operators

# F-String Interpolation
name = "Sol".
version = "1.0".
echo "Welcome to {name} v{version}!".

# Pipeline Operator and named helpers
double x = x * 2.
gtFive x = x > 5.
addUp a b = a + b.
numbers = [1, 2, 3, 4, 5].
result = numbers |> map double |> filter gtFive |> fold addUp 0.
echo "Pipeline result: {result}".

# Result Types with getenv
home = getenv "HOME" |> unwrap_or "/tmp".
echo "Home directory: {home}".

# Shell command with Result types
git_result = sh "git status".
is_success = succeeded git_result.
echo "Git command succeeded: {is_success}".

# Safe shell command with fallback
python_path = sh "which python3" |> unwrap_or "python3 not found".
echo "Python location: {python_path}".

# Complex pipeline with environment variable
user = whoami.
current_dir = getenv "PWD" |> unwrap_or ".".
echo "Running as {user} in {current_dir}".

# Data processing pipeline
data = [100, 200, 300, 400, 500].
doubled = data |> map double.
gtFiveHundred x = x > 500.
large_nums = doubled |> filter gtFiveHundred.
total = large_nums |> fold addUp 0.
echo "Sum of large doubled numbers: {total}".

# Result error handling
missing_var = getenv "NONEXISTENT_VAR" |> unwrap_or "default_value".
echo "Missing var value: {missing_var}".

# Dict access with new [] syntax
user_info = {"name": "Alice", "age": 30}.
echo "User {user_info["name"]} is {user_info["age"]} years old".

# Guards replacing if/then/else
score = 85.
grade | score > 90 = "A".
grade | score > 80 = "B".
grade | score > 70 = "C".
grade              = "D".
echo "Score {score} gets grade: {grade}".

echo "All Sol features demonstrated!".
