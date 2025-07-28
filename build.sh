#!/usr/bin/env bash

set -e

echo "Building Sol with Nuitka..."

# Clean previous builds
rm -rf build/ dist/ main.build/ main.dist/ main.onefile-build/ sol.build/ sol.dist/

# Build with Nuitka with best performance flags + single executable
uv run python -m nuitka \
    --onefile \
    --standalone \
    --assume-yes-for-downloads \
    --output-filename=sol \
    --output-dir=dist \
    --remove-output \
    --enable-plugin=no-qt \
    --include-module=warnings \
    --include-module=json \
    --include-module=csv \
    --include-module=hashlib \
    --include-module=platform \
    --include-module=socket \
    --include-module=subprocess \
    --include-module=getpass \
    --include-module=zipfile \
    --include-module=tarfile \
    --include-module=gzip \
    --include-module=shutil \
    --include-module=time \
    --include-module=difflib \
    --include-module=traceback \
    --report=compilation-report.xml \
    main.py

echo "Build completed successfully!"
echo "You can run it with: ./dist/sol"
