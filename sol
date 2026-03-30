#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve any file-path arguments to absolute paths before uv changes directory
ARGS=()
for arg in "$@"; do
  if [[ -f "$arg" ]]; then
    ARGS+=("$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")")
  else
    ARGS+=("$arg")
  fi
done

exec uv run --directory "$SCRIPT_DIR" python main.py "${ARGS[@]}"
