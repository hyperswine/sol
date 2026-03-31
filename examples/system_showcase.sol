# Sol Language - System Info Feature Showcase
echo "=== Sol System Information Features ===".

# Basic system info
echo "User and System:".
user = whoami.
host = hostname.
echo user.
echo host.

# CPU and Memory
echo "Hardware Info:".
cores = cpu_count.
cpu_usage = cpu_percent.
mem = memory.
echo "CPU cores:".
echo cores.
echo "CPU usage %:".
echo cpu_usage.
echo "Total memory bytes:".
echo mem.

# Environment Variables
echo "Environment:".
shell = getenv "SHELL".
home = getenv "HOME".
echo "Shell:".
echo shell.
echo "Home directory:".
echo home.

# Set custom environment variable
setenv "SOL_DEMO" "Working!".
demo_val = getenv "SOL_DEMO".
echo "Custom env var:".
echo demo_val.

# Platform information
echo "Platform:".
platform_info = platform.
echo platform_info.

# Disk usage
echo "Disk Usage:".
disk_info = disk_usage ".".
echo disk_info.

# System uptime
echo "Uptime (seconds):".
up = uptime.
echo up.

echo "=== System Info Features Complete! ===".
