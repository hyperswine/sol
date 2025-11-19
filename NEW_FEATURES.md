# Sol Language - New Features Implementation

This document describes the three new features that have been implemented for the Sol scripting language:

## 1. Result Types with Unwrap Functions

### Overview
Added a proper Result type for error handling, eliminating the need for match statements. Functions that can fail now return `Result` types that wrap either a success value or an error.

### Implementation
- **File**: `stdlib/result.py`
- **New Type**: `Result` - A dataclass with `success`, `value`, and `error` fields
- **Helper Functions**:
  - `ok(value)` - Create a successful Result
  - `err(error)` - Create an error Result
  - `unwrap_or(result, default_value)` - Unwrap Result or return default
  - `unwrap_or_exit(result, error_message)` - Unwrap Result or exit program
  - `failed(result)` - Check if Result is an error
  - `succeeded(result)` - Check if Result is successful

### Modified Functions
- `sh(command)` - Execute shell commands, returns Result with stdout/stderr/exit_code
- `getenv(key)` - Get environment variables, returns Result.Err if not found
- `exit(code)` - Exit the program with given code

### Usage Examples
```sol
# Check if command succeeded
docker_check = sh "docker --version".
if (failed docker_check) then
  echo "Error: Docker not installed"
  exit 1.

# Unwrap with default value
version = getenv "VERSION" |> unwrap_or "latest".

# Unwrap or exit with error message
sh "docker build -t myapp:latest ." |> unwrap_or_exit "Build failed".
```

## 2. Pipeline Operator |>

### Overview
Added the pipeline operator `|>` for chaining function calls in a readable left-to-right flow. The value on the left is passed as the **first argument** to the function on the right.

### Implementation
- **Parser Changes**: `parsing.py` - Added pipeline expression support with `|>` operator
- **Interpreter Changes**: `interpret.py` - Added `process_pipeline()` function
- Pipelines are parsed as `("PIPELINE", [initial_value, '|>', func1, args..., '|>', func2, ...])`
- Each pipeline stage inserts the current value as the first argument to the next function

### Syntax
```sol
value |> function           # function(value)
value |> function arg       # function(value, arg)
value |> func1 |> func2     # func2(func1(value))
```

### Usage Examples
```sol
# Simple pipeline
result = getenv "HOME" |> echo.

# Pipeline with arguments
version = getenv "VERSION" |> unwrap_or "latest".

# Multi-stage pipeline
services |> map build_service |> filter is_ready |> deploy.

# Chaining with Result types
sh "docker build -t app:latest ." |> unwrap_or_exit "Build failed".
```

## 3. F-Strings (String Interpolation)

### Overview
Added Python-style f-string interpolation for embedding variables in strings. Uses double quotes `""` for f-strings and single quotes `''` for regular strings.

### Implementation
- **Parser Changes**: `parsing.py` - Distinguish between f-strings and regular strings
  - `"text"` → `("FSTRING_LITERAL", "text")` - Supports `{variable}` interpolation
  - `'text'` → `("STRING_LITERAL", "text")` - No interpolation
- **Interpreter Changes**: `interpret.py` - Added `process_fstring_literal()` function
  - Uses regex to find `{variable}` patterns
  - Replaces them with variable values from environment
  - Non-existent variables are left as-is

### Syntax
```sol
# F-string with interpolation (double quotes)
name = "World".
echo "Hello, {name}!".        # Prints: Hello, World!

# Regular string (single quotes)
echo 'Hello, {name}!'.        # Prints: Hello, {name}!

# Multiple variables
service = "api".
version = "v1.2.3".
echo "Building {service}:{version}".  # Prints: Building api:v1.2.3
```

### Usage Examples
```sol
# Deployment script with all features
version = getenv "VERSION" |> unwrap_or "latest".
registry = getenv "REGISTRY" |> unwrap_or "registry.io".
service = "myapp".

echo "Deploying {service}:{version} to {registry}".

# Build with error handling
result = sh "docker build -t {service}:{version} .".
if (failed result) then
  echo "Build failed for {service}:"
  echo result|stderr
  exit 1.

# Success message
echo "Successfully deployed {service}:{version}!".
```

## Combined Example

Here's a complete example using all three features together:

```sol
#!/usr/bin/env sol

echo "=== Deployment Script ===".

# Get configuration with defaults (Result + Pipeline + F-strings)
version = getenv "VERSION" |> unwrap_or "latest".
registry = getenv "REGISTRY" |> unwrap_or "registry.io".
services = ["api", "worker", "frontend"].

# Check prerequisites (Result types)
docker_check = sh "docker --version".
if (failed docker_check) then
  echo "Error: Docker not installed"
  exit 1.

# Build services
echo "Building services...".
services |> map (\service ->
  echo "Building {service}...".
  result = sh "docker build -t {service}:latest ./services/{service}".
  if (failed result) then
    echo "Build failed for {service}:"
    echo result|stderr
    exit 1.
).

# Tag and push (Pipeline + F-strings)
services |> map (\service ->
  tag = "{registry}/{service}:{version}".
  sh "docker tag {service}:latest {tag}" |> unwrap_or_exit "Tag failed for {service}".
  sh "docker push {tag}" |> unwrap_or_exit "Push failed for {service}".
).

echo "=== Deployed {version} successfully! ===".
```

## Testing

Run the test suite to verify all features:
```bash
.venv/bin/python test_new_features.py
```

Or run the demo:
```bash
./main.py examples/new_features_demo.sol
```

## Files Modified

1. **stdlib/result.py** (NEW) - Result type and unwrap functions
2. **stdlib/system.py** - Added `sh()` function, updated `getenv()` to return Result
3. **stdlib/__init__.py** - Registered new functions in FUNCTION_MAP
4. **parsing.py** - Added pipeline operator and f-string parsing
5. **interpret.py** - Added pipeline and f-string processing

## Status

✅ Result types - Fully implemented and working
✅ Pipeline operator - Fully implemented and working
✅ F-strings - Fully implemented and working
✅ Combined usage - All features work together seamlessly

All features are production-ready and match the specifications in DESIGN.md.
