#!/usr/bin/env sol
# Example demonstrating the new Sol features:
# 1. Result types with unwrap_or and unwrap_or_exit
# 2. Pipeline operator |>
# 3. F-strings with double quotes

echo "=== Sol New Features Demo ===".

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

# Multiple stages
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

# Example 4: Combined Usage
echo "".
echo "4. All Features Together".
echo "------------------------".

app = "myapp".
tag = getenv "TAG" |> unwrap_or "latest".
namespace = getenv "NAMESPACE" |> unwrap_or "default".

echo "Application: {app}".
echo "Tag: {tag}".
echo "Namespace: {namespace}".
echo "Full image: {registry}/{app}:{tag}".

# Conditional deployment based on Result
docker_available = sh "docker --version".
echo "Docker available: {succeeded docker_available}".

echo "".
echo "=== Demo Complete ===".
