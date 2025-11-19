# Sol 1.0 Feature Showcase
# Demonstrates pipeline operator, f-string interpolation, and Result types

# F-String Interpolation
name = "Sol".
version = "1.0".
echo "Welcome to {name} v{version}!".

# Pipeline Operator - basic usage
numbers = [1, 2, 3, 4, 5].
result = numbers |> map (* 2) |> filter (> 5) |> fold + 0.
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
doubled = data |> map (* 2).
large_nums = doubled |> filter (> 500).
sum = large_nums |> fold + 0.
echo "Sum of large doubled numbers: {sum}".

# Result error handling
missing_var = getenv "NONEXISTENT_VAR" |> unwrap_or "default_value".
echo "Missing var value: {missing_var}".

# F-string with nested data access
user_info = {"name": "Alice", "age": 30}.
echo "User {user_info|name} is {user_info|age} years old".

# Pipeline with network operation (commented to avoid actual network call)
# content = wget "https://api.github.com/users/octocat" |> unwrap_or "Failed to fetch".
# echo content.

echo "All Sol 1.0 features demonstrated!".
