Sol is a modern, minimal, batteries-included scripting language designed for readability, quick startup, and powerful standard tooling. Built on Python's extensive ecosystem, Sol provides a highly expressive scripting experience with clean syntax.

- **Syntax**: Statements end with periods (`.`) like natural language
- **Prefix Function Calls**: `result = func arg1 arg2`
- **Built-in Tools**: File operations, OS commands, all using Python's libraries
- **Fast Startup**: Minimal runtime overhead
- **No Dependencies**: Everything you need is built-in

```sol
echo "Hello World".
```

```sol
current_dir = pwd.
echo current_dir.
```

```sol
mkdir "my_directory".
write "test.txt" "Hello Sol!".
content = read "test.txt".
```

## BUILT-IN FUNCTIONS

Sol comes with a comprehensive standard library providing filesystem operations, networking, data processing, system information, and more. All functions are implemented using Python's standard library for maximum compatibility and reliability.

### **Filesystem Operations**

- **`ls [path]`** - List directory contents
  - Without arguments: Lists current directory contents
  - With path: Lists specified directory contents
  - Returns: List of filenames and directories
  - Example: `files = ls "src".`

- **`pwd`** - Get current working directory
  - Returns: Absolute path of current directory as string
  - Example: `current = pwd.`

- **`mkdir path`** - Create directory
  - Creates directory and any necessary parent directories
  - Returns: Success message or error description
  - Example: `mkdir "project/src".`

- **`rm path`** - Remove file or directory
  - Removes files or directories recursively
  - Returns: Success message or error description
  - Example: `rm "temp_file.txt".`

- **`read path`** - Read file contents
  - Reads entire file content as string
  - Returns: File contents or error message
  - Example: `content = read "config.txt".`

- **`write path content`** - Write content to file
  - Writes string content to file, creating file if needed
  - Returns: Success message or error description
  - Example: `write "output.txt" "Hello World".`

- **`cp source destination`** - Copy file or directory
  - Copies files or directories (including subdirectories)
  - Returns: Success message or error description
  - Example: `cp "file.txt" "backup.txt".`
  - Example: `cp "mydir" "backup_dir".`

- **`mv source destination`** - Move/rename file or directory
  - Moves or renames files and directories
  - Returns: Success message or error description
  - Example: `mv "old_name.txt" "new_name.txt".`
  - Example: `mv "folder" "new_location/folder".`

- **`touch path`** - Create empty file or update timestamp
  - Creates empty file if it doesn't exist, updates timestamp if it does
  - Creates parent directories as needed
  - Returns: Success message or error description
  - Example: `touch "new_file.txt".`

- **`chmod path mode`** - Change file permissions
  - Changes file permissions using Unix-style octal notation
  - Returns: Success message or error description
  - Example: `chmod "script.sh" "755".`

- **`find [directory] [pattern]`** - Find files matching pattern
  - Searches recursively for files matching glob pattern
  - Default directory: current directory, default pattern: "*"
  - Returns: List of matching files
  - Example: `files = find "src" "*.py".`

- **`du [path]`** - Get directory size and file count
  - Calculates total size, file count, and directory count
  - Default path: current directory
  - Returns: Dictionary with size, files, and directories count
  - Example: `size_info = du "project".`

### **Git Operations**

- **`git_status`** - Get git repository status
  - Shows modified, added, deleted files
  - Returns: Git status output or "Working directory clean"
  - Example: `status = git_status.`

- **`git_add [path]`** - Add files to staging area
  - Adds files to git staging area (default: all files)
  - Returns: Success message or error description
  - Example: `git_add "file.txt".`
  - Example: `git_add ".".`

- **`git_commit [message]`** - Commit staged changes
  - Commits staged changes with message (default: "Quick Update")
  - Returns: Success message or error description
  - Example: `git_commit "Fix bug in parser".`

- **`git_push`** - Push commits to remote
  - Pushes committed changes to remote repository
  - Returns: Success message or error description
  - Example: `git_push.`

- **`git_pull`** - Pull changes from remote
  - Pulls latest changes from remote repository
  - Returns: Success message or error description
  - Example: `git_pull.`

- **`git_fetch`** - Fetch changes from remote
  - Fetches changes without merging
  - Returns: Success message or error description
  - Example: `git_fetch.`

- **`gitupdate`** - Quick commit workflow
  - Performs: git add . → git commit -m "Quick Update"
  - Returns: Success message or error description
  - Example: `gitupdate.`

- **`gitpush`** - Quick push workflow
  - Performs: git add . → git commit -m "Quick Update" → git push
  - Returns: Success message or error description
  - Example: `gitpush.`

- **`gitsync`** - Full synchronization workflow
  - Performs: git add . → git commit → git push → git fetch → git pull
  - Returns: Success message or error description
  - Example: `gitsync.`

- **`git_log [count]`** - Show commit history
  - Shows last N commits in one-line format (default: 10)
  - Returns: Commit history or "No commits found"
  - Example: `recent_commits = git_log 5.`

- **`git_branch`** - List git branches
  - Shows all local branches with current branch marked
  - Returns: Branch list
  - Example: `branches = git_branch.`

### **Arithmetic Operations**

- **`+ value1 value2 [value3...]`** - Addition and concatenation
  - Numbers: Performs arithmetic addition
  - Strings: Concatenates strings together
  - Supports multiple arguments for chaining
  - Can create partial functions: `add_five = + 5.`
  - Example: `result = + 10 20 30.` (returns 60)

- **`- number1 number2`** - Subtraction
  - Subtracts second number from first
  - Can create partial functions: `subtract_ten = - 10.`
  - Example: `result = - 100 25.` (returns 75)

- **`* number1 number2`** - Multiplication
  - Multiplies two numbers together
  - Can create partial functions: `double = * 2.`
  - Example: `result = * 6 7.` (returns 42)

- **`/ number1 number2`** - Division
  - Divides first number by second
  - Handles division by zero with error message
  - Can create partial functions: `half = / 2.`
  - Example: `result = / 100 4.` (returns 25)

### **Comparison and Logic**

- **`> threshold`** - Greater than predicate
  - Creates a function that tests if value > threshold
  - Used with filter and other higher-order functions
  - Example: `big_nums = filter (> 10) numbers.`

- **`< threshold`** - Less than predicate
  - Creates a function that tests if value < threshold
  - Used with filter and other higher-order functions
  - Example: `small_nums = filter (< 5) numbers.`

- **`== value`** - Equality predicate
  - Creates a function that tests if value equals given value
  - Works with any data type
  - Example: `matches = filter (== "target") strings.`

### **Higher-Order Functions**

- **`map function array`** - Apply function to each element
  - Applies function to every element in array
  - Returns new array with transformed elements
  - Works with partial functions and predicates
  - Example: `doubled = map (* 2) [1, 2, 3].` (returns [2, 4, 6])

- **`filter predicate array`** - Filter array elements
  - Keeps only elements where predicate returns true
  - Returns new array with filtered elements
  - Example: `evens = filter (== 0) remainders.`

- **`fold function array [initial]`** - Reduce array with function
  - Reduces array to single value using function
  - Optional initial value for accumulator
  - Example: `sum = fold + [1, 2, 3, 4].` (returns 10)

- **`progress expression`** - Execute expression with progress indication
  - Wraps any function call or value with visual progress feedback
  - For network operations (wget, get): Shows real-time progress bar based on download size
  - For file operations: Shows spinner during execution
  - For simple computations: Shows quick 0-100% animation
  - Returns the result of the wrapped expression
  - Example: `content = progress (wget "https://example.com/file.txt").`
  - Example: `result = progress (+ 10 20).`
  - Example: `data = progress (read "large_file.txt").`

### **System Information**

- **`whoami`** - Get current username
  - Returns: Current system username as string
  - Example: `user = whoami.`

- **`hostname`** - Get system hostname
  - Returns: Computer's hostname as string
  - Example: `host = hostname.`

- **`getenv var_name`** - Get environment variable
  - Returns: Environment variable value or empty string
  - Example: `home = getenv "HOME".`

- **`setenv var_name value`** - Set environment variable
  - Sets environment variable for current process
  - Returns: Confirmation message
  - Example: `setenv "MY_VAR" "test_value".`

- **`listenv`** - List all environment variables
  - Returns: Dictionary of all environment variables
  - Example: `env_vars = listenv.`

- **`platform`** - Get platform information
  - Returns: Dictionary with system, machine, processor, architecture, Python version
  - Example: `sys_info = platform.`

- **`cpu_count`** - Get number of CPU cores
  - Returns: Number of logical CPU cores
  - Example: `cores = cpu_count.`

- **`cpu_percent`** - Get current CPU usage percentage
  - Returns: Current CPU usage as percentage (0-100)
  - Takes 1 second to measure
  - Example: `usage = cpu_percent.`

- **`memory`** - Get memory usage information
  - Returns: Dictionary with total, available, percent, used, free memory
  - All values in bytes except percent
  - Example: `mem_info = memory.`

- **`disk_usage [path]`** - Get disk usage statistics
  - Path defaults to current directory if not specified
  - Returns: Dictionary with total, used, free space and percent
  - Example: `disk_info = disk_usage "/".`

- **`uptime`** - Get system uptime in seconds
  - Returns: Number of seconds since system boot
  - Example: `boot_time = uptime.`

- **`processes`** - Get list of running processes
  - Returns: List of top 20 processes with PID, name, CPU percent
  - Example: `proc_list = processes.`

### **Web and Network Operations**

- **`wget url`** - Download content from URL
  - Downloads content from web URL
  - Returns: Downloaded content as string or error message
  - Example: `content = wget "https://api.github.com/users/octocat".`

- **`get url`** - Make HTTP GET request
  - Makes HTTP GET request to specified URL
  - Returns: Response content or error message
  - Example: `response = get "https://httpbin.org/get".`

- **`post url [data]`** - Make HTTP POST request
  - Makes HTTP POST request with optional data payload
  - Data can be dictionary or string
  - Returns: Response content or error message
  - Example: `response = post "https://httpbin.org/post" {"key": "value"}.`

- **`ping host [count]`** - Ping a host
  - Pings specified host (default 4 packets)
  - Returns: Ping results as string
  - Example: `result = ping "google.com" 3.`

- **`dns_lookup hostname`** - Perform DNS lookup
  - Resolves hostname to IP address
  - Returns: Dictionary with hostname and IP
  - Example: `ip_info = dns_lookup "github.com".`

- **`whois domain`** - Get WHOIS information
  - Retrieves WHOIS information for domain
  - Requires system whois command
  - Returns: WHOIS output as string
  - Example: `info = whois "example.com".`

- **`nmap target [ports]`** - Basic port scan
  - Performs port scan using nmap (must be installed)
  - Default ports: 1-1000
  - Returns: Nmap output as string
  - Example: `scan = nmap "192.168.1.1" "1-100".`

- **`port_scan host port`** - Check if specific port is open
  - Tests connectivity to specific host and port
  - Returns: Status message indicating open/closed
  - Example: `status = port_scan "github.com" 443.`

### **Compression and Archives**

- **`zip_create archive.zip file1 file2 ...`** - Create ZIP archive
  - Creates ZIP archive containing specified files
  - Returns: Success message or error description
  - Example: `zip_create "backup.zip" "file1.txt" "file2.txt".`

- **`zip_extract archive.zip [destination]`** - Extract ZIP archive
  - Extracts ZIP archive to destination (default: current directory)
  - Returns: Success message or error description
  - Example: `zip_extract "backup.zip" "restore_folder".`

- **`tar_create archive.tar file1 file2 ...`** - Create TAR archive
  - Creates TAR archive (supports .tar.gz for compression)
  - Returns: Success message or error description
  - Example: `tar_create "backup.tar.gz" "src" "docs".`

- **`tar_extract archive.tar [destination]`** - Extract TAR archive
  - Extracts TAR archive to destination
  - Returns: Success message or error description
  - Example: `tar_extract "backup.tar.gz" "restore".`

- **`gzip_compress file [output]`** - Compress file with GZIP
  - Compresses file using GZIP algorithm
  - Output defaults to file.gz if not specified
  - Returns: Success message or error description
  - Example: `gzip_compress "large_file.txt" "compressed.gz".`

- **`gzip_decompress file.gz [output]`** - Decompress GZIP file
  - Decompresses GZIP file
  - Output defaults to original name without .gz
  - Returns: Success message or error description
  - Example: `gzip_decompress "compressed.gz" "restored.txt".`

### **Data Processing**

- **`jsonread filepath`** - Read and parse JSON file
  - Reads JSON file and parses into Sol data structures
  - Returns: Parsed JSON data or error message
  - Example: `config = jsonread "settings.json".`

- **`jsonwrite data filepath`** - Write data to JSON file
  - Converts Sol data to JSON and writes to file
  - Pretty-prints with 2-space indentation
  - Returns: Success message or error description
  - Example: `jsonwrite config "settings.json".`

- **`jsonparse json_string`** - Parse JSON string
  - Parses JSON string into Sol data structures
  - Returns: Parsed data or error message
  - Example: `data = jsonparse "{"name": "Sol", "version": "0.1"}".`

- **`jsonstringify data`** - Convert data to JSON string
  - Converts Sol data structures to JSON string
  - Pretty-prints with 2-space indentation
  - Returns: JSON string representation
  - Example: `json_str = jsonstringify {"name": "Sol"}.`

- **`csvread filepath [delimiter] [has_header]`** - Read CSV file
  - Reads CSV file into list of lists (rows and columns)
  - Default delimiter: comma, default has_header: true
  - Returns: Array of arrays or error message
  - Example: `data = csvread "data.csv" "," true.`

- **`csvwrite data filepath [delimiter]`** - Write data to CSV file
  - Writes array of arrays to CSV file
  - Default delimiter: comma
  - Returns: Success message or error description
  - Example: `csvwrite rows "output.csv" ",".`

- **`csvparse csv_string [delimiter]`** - Parse CSV string
  - Parses CSV string into array of arrays
  - Default delimiter: comma
  - Returns: Parsed data or error message
  - Example: `data = csvparse "name,age\nJohn,25\nJane,30".`

- **`set data path value`** - Set value in nested structure
  - Sets value in nested dictionary/array using path
  - Path uses "|" separator (e.g., "key1|index|key2")
  - Works with both dictionaries and arrays (1-indexed)
  - Returns: Updated data structure or error message
  - Example: `updated = set data "user|name" "NewName".`

### **Type Conversion**

- **`to_number value`** - Convert value to number
  - Converts strings or other values to int or float
  - Returns: Number or error message if conversion fails
  - Example: `num = to_number "42.5".` (returns 42.5)

- **`to_string value`** - Convert value to string
  - Converts any value to its string representation
  - Handles booleans, None, and complex data structures
  - Returns: String representation of value
  - Example: `str_val = to_string 123.` (returns "123")

### **Utilities**

- **`echo text`** - Print text to stdout
  - Outputs any value as text
  - Handles all data types with proper formatting
  - Returns: String representation of input
  - Example: `echo "Hello World".`

- **`md5 text`** - Calculate MD5 hash
  - Calculates MD5 hash of text as hexadecimal string
  - Returns: 32-character hex string
  - Example: `hash = md5 "password123".`

- **`sha256 text`** - Calculate SHA256 hash
  - Calculates SHA256 hash of text as hexadecimal string
  - Returns: 64-character hex string
  - Example: `secure_hash = sha256 "sensitive_data".`

### **Data Structures**

Sol supports rich data structures with literal syntax:

- **Arrays**: `[1, 2, 3]` - Ordered collections with 1-based indexing
- **Dictionaries**: `{"key": "value", "num": 42}` - Key-value mappings
- **Nested structures**: `[{"name": "Sol"}, [1, 2]]` - Full nesting support
- **Access syntax**: `data|key|1|subkey` - Chain access with | separator
- **Variable interpolation**: `data|(variable)` - Use variable values as keys

## USAGE

### Script Execution

```bash
uv run python main.py script.sol
```

### Interactive Mode

```bash
uv run python main.py
```

### Debug Mode

```bash
uv run python main.py --debug script.sol  # For script files
uv run python main.py --debug             # For interactive mode
```

## EXAMPLES

### **Basic Operations**

```sol
# File and directory operations
echo "Setting up project structure".
mkdir "my_project".
mkdir "my_project/src".
mkdir "my_project/docs".

# Write configuration files
config = {"name": "MyProject", "version": "1.0", "debug": true}.
jsonwrite config "my_project/config.json".

# Read and display
project_config = jsonread "my_project/config.json".
echo "Project configuration:".
echo project_config.
```

### **System Information and Monitoring**

```sol
# Get comprehensive system information
user = whoami.
host = hostname.
cores = cpu_count.
cpu_usage = cpu_percent.
mem_info = memory.
disk_info = disk_usage.

echo "=== System Information ===".
echo + "User: " user.
echo + "Host: " host.
echo + "CPU Cores: " (to_string cores).
echo + "CPU Usage: " (to_string cpu_usage) "%".
echo + "Memory Usage: " (to_string mem_info|percent) "%".
```

### **Data Processing and Analysis**

```sol
# Create sample data
data = [10, 25, 5, 30, 45, 15, 35].
echo "Original data:".
echo data.

# Filter and transform data
high_values = filter (> 20) data.
doubled = map (* 2) high_values.
total = fold + doubled.

echo "High values (>20):".
echo high_values.
echo "Doubled high values:".
echo doubled.
echo "Sum of doubled high values:".
echo total.
```

### **Web and Network Operations**

```sol
# Network diagnostics
echo "=== Network Diagnostics ===".

# DNS lookup
github_dns = dns_lookup "github.com".
echo "GitHub DNS:".
echo github_dns.

# Port scanning
ssh_status = port_scan "github.com" 22.
https_status = port_scan "github.com" 443.
echo ssh_status.
echo https_status.

# Ping test
ping_result = ping "8.8.8.8" 3.
echo "Ping results:".
echo ping_result.
```

### **Data Format Conversion**

```sol
# Working with different data formats
sample_data = [
  {"name": "Alice", "age": 30, "city": "New York"},
  {"name": "Bob", "age": 25, "city": "San Francisco"},
  {"name": "Charlie", "age": 35, "city": "Chicago"}
].

# Convert to JSON
json_output = jsonstringify sample_data.
write "people.json" json_output.

# Create CSV version
csv_data = [
  ["name", "age", "city"],
  ["Alice", "30", "New York"],
  ["Bob", "25", "San Francisco"],
  ["Charlie", "35", "Chicago"]
].
csvwrite csv_data "people.csv".

echo "Data saved in both JSON and CSV formats".
```

### **File Compression and Archives**

```sol
# Create test files
write "document1.txt" "This is the first document with important data.".
write "document2.txt" "This is the second document with more information.".
write "document3.txt" "This is the third document completing our dataset.".

# Create different types of archives
zip_result = zip_create "documents.zip" "document1.txt" "document2.txt" "document3.txt".
tar_result = tar_create "documents.tar.gz" "document1.txt" "document2.txt" "document3.txt".

echo zip_result.
echo tar_result.

# Compress individual file
gzip_result = gzip_compress "document1.txt".
echo gzip_result.

# Extract and verify
mkdir "extracted".
zip_extract "documents.zip" "extracted".
ls "extracted".
```

### **Environment and Process Management**

```sol
# Environment variables
home_dir = getenv "HOME".
path_var = getenv "PATH".
echo + "Home directory: " home_dir.

# Set custom environment variable
setenv "MY_APP_CONFIG" "/etc/myapp.conf".
config_path = getenv "MY_APP_CONFIG".
echo + "Config path: " config_path.

# Process information
running_processes = processes.
echo "Top running processes:".
echo running_processes.
```

### **Advanced Functional Programming**

```sol
# Complex data transformation pipeline
numbers = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].

# Create reusable functions
is_even = filter (== 0).
multiply_by_three = map (* 3).
greater_than_ten = filter (> 10).

# Process even numbers
even_numbers = is_even (map (% 2) numbers).  # Get remainders, then filter zeros
tripled_evens = multiply_by_three even_numbers.
big_tripled_evens = greater_than_ten tripled_evens.

echo "Original numbers:".
echo numbers.
echo "Even numbers tripled (>10):".
echo big_tripled_evens.

# Statistical operations
sum_all = fold + numbers.
count = fold + (map (* 0) numbers).  # Convert to zeros, then count
average = / sum_all count.

echo + "Average: " (to_string average).
```

### **File Management and Git Workflow**

```sol
# Project setup and file management
echo "=== Setting up project structure ===".

# Create project directories
mkdir "my_project".
mkdir "my_project/src".
mkdir "my_project/docs".
mkdir "my_project/tests".

# Create some sample files
write "my_project/README.md" "# My Project\n\nThis is a sample project.".
write "my_project/src/main.py" "print('Hello World')".
write "my_project/tests/test_main.py" "# Test file".

# Copy important files
cp "my_project/README.md" "my_project/docs/README_backup.md".

# Set executable permissions for scripts
chmod "my_project/src/main.py" "755".

# Find all Python files
python_files = find "my_project" "*.py".
echo "Python files found:".
echo python_files.

# Check directory size
project_size = du "my_project".
echo "Project size information:".
echo project_size.
```

### **Git Version Control Workflow**

```sol
# Initialize and set up git repository (assumes git repo exists)
echo "=== Git workflow demonstration ===".

# Check current status
status = git_status.
echo "Current git status:".
echo status.

# Quick update workflow
echo "Performing quick update...".
update_result = gitupdate.
echo update_result.

# View recent commits
echo "Recent commit history:".
commits = git_log 5.
echo commits.

# Full sync with remote
echo "Performing full sync...".
sync_result = gitsync.
echo sync_result.

# Check branches
echo "Available branches:".
branches = git_branch.
echo branches.
```

### **Integrated Project Management**

```sol
# Combined filesystem and git operations
echo "=== Integrated project management ===".

# Create a new feature
mkdir "feature_branch".
write "feature_branch/new_feature.py" "# New feature implementation".

# Copy to main project
cp "feature_branch/new_feature.py" "my_project/src/".

# Clean up temporary directory
rm "feature_branch".

# Stage and commit the changes
git_add "my_project/src/new_feature.py".
commit_result = git_commit "Add new feature implementation".
echo commit_result.

# Push to remote
push_result = git_push.
echo push_result.

# Verify the changes
final_status = git_status.
echo "Final status:".
echo final_status.
```

### **Nested Data Structure Manipulation**

```sol
# Complex nested data structure
company_data = {
  "company": "Tech Corp",
  "employees": [
    {"name": "Alice", "department": "Engineering", "salary": 95000},
    {"name": "Bob", "department": "Marketing", "salary": 75000},
    {"name": "Charlie", "department": "Engineering", "salary": 105000}
  ],
  "locations": ["New York", "San Francisco", "Austin"]
}.

# Access nested data
company_name = company_data|company.
first_employee = company_data|employees|1.
first_location = company_data|locations|1.

echo + "Company: " company_name.
echo "First employee:".
echo first_employee.
echo + "First location: " first_location.

# Modify nested data
updated_data = set company_data "employees|1|salary" 100000.
alice_new_salary = updated_data|employees|1|salary.
echo + "Alice's updated salary: " (to_string alice_new_salary).
```

## PRINCIPLES

Sol is designed around several core principles:

1. **Readability First** - Code should read like natural language
2. **Minimal Syntax** - Less cognitive overhead, more focus on problem-solving
3. **Batteries Included** - Rich standard library for common tasks
4. **Functional Style** - Encourage immutable data and function composition
5. **Helpful Errors** - Detailed error messages with suggestions and context
6. **Zero Setup** - No package management, no build systems, just Python

Sol bridges the gap between shell scripting and full programming languages, offering the simplicity of shell commands with the power and structure of modern functional programming.
