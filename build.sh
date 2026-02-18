#!/usr/bin/env bash
set -euo pipefail

# Make output directory
mkdir -p .out

# Get version from git tags
VERSION=$(git describe --tags --abbrev=0 2>/dev/null || echo "dev")
REPO_NAME=$(basename "$(pwd)")
REPO_NAME_LOWER=$(echo "$REPO_NAME" | tr '[:upper:]' '[:lower:]')

ZIP_NAME=".out/${REPO_NAME_LOWER}-${VERSION}.zip"

# Find top-level directories, excluding hidden ones, and zip them
find . -mindepth 1 -maxdepth 1 -type d ! -name ".*" | zip -r "$ZIP_NAME" -@

echo "Created release zip: $ZIP_NAME"
