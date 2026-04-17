#!/usr/bin/env sol
# Example demonstrating Sol features:
# 1. Result types with unwrap_or and unwrap_or_exit
# 2. Pipeline operator |>
# 3. F-strings with double quotes
# 4. Guards replacing if/then/else
# 5. Infix operators

echo "=== Sol Features Demo ===".

# Example 1: Result Types
echo "".
echo "1. Result Types".
echo "---------------".

# Get environment variable with fallback
version = getenv "VERSION" |> unwrap_or "1.0.0".
echo "Version: {version}".

# Shell commands return Results
check = sh "which docker".
echo "Docker check result: {check}".
echo "Docker installed: {succeeded check}".

# Example 2: Pipeline Operator
echo "".
echo "2. Pipeline Operator".
echo "--------------------".

# Chain operations with |>
config_path = getenv "CONFIG_PATH" |> unwrap_or "/etc/config".
echo "Config path: {config_path}".

registry = getenv "REGISTRY" |> unwrap_or "registry.io".
echo "Registry: {registry}".

# Example 3: F-Strings
echo "".
echo "3. F-String Interpolation".
echo "-------------------------".

service = "api".
env = "production".
replicas = 3.

echo "Deploying {service} to {env} with {replicas} replicas".

# Example 4: Infix Operators and Guards
echo "".
echo "4. Infix Operators and Guards".
echo "-----------------------------".

x = 42.
category | x > 100 = "large".
category | x > 10  = "medium".
category            = "small".
echo "x={x} is {category}".

double n = n * 2.
triple n = n * 3.
echo "double 5 = {double 5}".
echo "triple 5 = {triple 5}".

# Example 5: Combined Usage
echo "".
echo "5. All Features Together".
echo "------------------------".

app = "myapp".
tag = getenv "TAG" |> unwrap_or "latest".
namespace = getenv "NAMESPACE" |> unwrap_or "default".

echo "Application: {app}".
echo "Tag: {tag}".
echo "Namespace: {namespace}".
echo "Full image: {registry}/{app}:{tag}".

docker_available = sh "docker --version".
echo "Docker available: {succeeded docker_available}".

echo "".
echo "=== Demo Complete ===".
