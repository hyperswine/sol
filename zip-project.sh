#!/usr/bin/env bash
# zip-project.sh
# Zips everything in the current directory except dist-newstyle/

set -euo pipefail

if [ $# -ge 1 ]; then
  ARCHIVE_NAME="$1"
else
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  ARCHIVE_NAME="sol_${TIMESTAMP}.zip"
fi

echo "Creating: $ARCHIVE_NAME"
echo "Excluding: dist-newstyle/"

zip -r "$ARCHIVE_NAME" . \
  -x "dist-newstyle/*" \
  -x "*/dist-newstyle/*" \
  -x "dist-newstyle" \
  -x "bin/*" \
  -x ".git/*" \
  -x "*.zip"

echo "✓ Created $ARCHIVE_NAME"
