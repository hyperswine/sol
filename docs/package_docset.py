#!/usr/bin/env python3
"""
Sol Docset Packager

Creates a distributable archive of the Sol Dash docset.
"""

import os
import tarfile
import zipfile
from pathlib import Path
import shutil

def create_distribution():
    """Create distributable packages of the Sol docset"""
    docs_dir = Path(__file__).parent
    docset_path = docs_dir / "Sol.docset"

    if not docset_path.exists():
        print("Sol.docset not found. Run generate_docset.py first.")
        return

    # Create distribution directory
    dist_dir = docs_dir / "dist"
    dist_dir.mkdir(exist_ok=True)

    # Create tarball (for Linux/Unix)
    print("Creating tarball...")
    with tarfile.open(dist_dir / "Sol.docset.tar.gz", "w:gz") as tar:
        tar.add(docset_path, arcname="Sol.docset")

    # Create zip file (for Windows/general use)
    print("Creating zip file...")
    with zipfile.ZipFile(dist_dir / "Sol.docset.zip", "w", zipfile.ZIP_DEFLATED) as zip_file:
        for root, dirs, files in os.walk(docset_path):
            for file in files:
                file_path = Path(root) / file
                arcname = file_path.relative_to(docset_path.parent)
                zip_file.write(file_path, arcname)

    # Create installation script for macOS
    install_script = '''#!/bin/bash
# Sol Docset Installation Script for macOS

DOCSET_DIR="$HOME/Library/Application Support/Dash/DocSets"
CURRENT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing Sol docset for Dash..."

# Check if Dash directory exists
if [ ! -d "$DOCSET_DIR" ]; then
    echo "Creating Dash DocSets directory..."
    mkdir -p "$DOCSET_DIR"
fi

# Remove existing Sol docset
if [ -d "$DOCSET_DIR/Sol.docset" ]; then
    echo "Removing existing Sol docset..."
    rm -rf "$DOCSET_DIR/Sol.docset"
fi

# Copy new docset
echo "Copying Sol.docset..."
cp -r "$CURRENT_DIR/Sol.docset" "$DOCSET_DIR/"

echo "Sol docset installed successfully!"
echo "Please restart Dash to see the changes."
'''

    with open(dist_dir / "install-macos.sh", 'w') as f:
        f.write(install_script)

    os.chmod(dist_dir / "install-macos.sh", 0o755)

    # Create installation instructions
    instructions = '''# Sol Docset Installation

Choose the installation method for your system:

## macOS (Dash)

### Method 1: Automatic Installation
```bash
./install-macos.sh
```

### Method 2: Manual Installation
1. Extract `Sol.docset.zip` or `Sol.docset.tar.gz`
2. Copy `Sol.docset` to `~/Library/Application Support/Dash/DocSets/`
3. Restart Dash

## Linux (Zeal)

1. Extract `Sol.docset.tar.gz`:
   ```bash
   tar -xzf Sol.docset.tar.gz
   ```
2. Copy to Zeal docsets directory:
   ```bash
   cp -r Sol.docset ~/.local/share/Zeal/Zeal/docsets/
   ```
3. Restart Zeal

## Windows (Zeal)

1. Extract `Sol.docset.zip`
2. Copy `Sol.docset` folder to `%APPDATA%\\Zeal\\Zeal\\docsets\\`
3. Restart Zeal

## Features

- 50+ built-in functions documented
- Searchable function index
- Code examples and syntax highlighting
- Categorized organization
- Offline access

For more information, visit: https://github.com/hyperswine/Playground/tree/main/sol
'''

    with open(dist_dir / "INSTALL.md", 'w') as f:
        f.write(instructions)

    print(f"Distribution packages created in {dist_dir}")
    print("Files created:")
    for file in dist_dir.iterdir():
        if file.is_file():
            size = file.stat().st_size
            print(f"   - {file.name} ({size:,} bytes)")

if __name__ == "__main__":
    create_distribution()
