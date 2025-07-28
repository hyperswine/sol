#!/usr/bin/env sol
# File system operations example

echo "=== File System Operations ===".

# Create a test directory
mkdir "example_dir".

# Show current directory contents
echo "Current directory contents:".
files = ls.
echo files.

# Create a test file
echo "Creating a test file...".
write "example_dir/test.txt" "Hello from Sol scripting language!".

# Read the file back
echo "Reading the file:".
content = read "example_dir/test.txt".
echo content.

echo "=== End Example ===".
