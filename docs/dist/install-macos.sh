#!/bin/bash
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
