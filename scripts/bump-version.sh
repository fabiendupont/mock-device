#!/bin/bash
# bump-version.sh - Increment version and update all files

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VERSION_FILE="$PROJECT_ROOT/VERSION"

usage() {
    echo "Usage: $0 [major|minor|patch|VERSION]"
    echo
    echo "Examples:"
    echo "  $0 patch        # 1.0.0 -> 1.0.1"
    echo "  $0 minor        # 1.0.0 -> 1.1.0"
    echo "  $0 major        # 1.0.0 -> 2.0.0"
    echo "  $0 1.2.3        # Set to 1.2.3"
    exit 1
}

if [ $# -ne 1 ]; then
    usage
fi

# Read current version
if [ ! -f "$VERSION_FILE" ]; then
    echo "ERROR: VERSION file not found at $VERSION_FILE"
    exit 1
fi

CURRENT_VERSION=$(cat "$VERSION_FILE")
echo "Current version: $CURRENT_VERSION"

# Parse version
if [[ $CURRENT_VERSION =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    MAJOR="${BASH_REMATCH[1]}"
    MINOR="${BASH_REMATCH[2]}"
    PATCH="${BASH_REMATCH[3]}"
else
    echo "ERROR: Invalid version format in VERSION file: $CURRENT_VERSION"
    exit 1
fi

# Calculate new version
case "$1" in
    major)
        NEW_VERSION="$((MAJOR + 1)).0.0"
        ;;
    minor)
        NEW_VERSION="$MAJOR.$((MINOR + 1)).0"
        ;;
    patch)
        NEW_VERSION="$MAJOR.$MINOR.$((PATCH + 1))"
        ;;
    [0-9]*.[0-9]*.[0-9]*)
        NEW_VERSION="$1"
        ;;
    *)
        echo "ERROR: Invalid argument: $1"
        usage
        ;;
esac

echo "New version: $NEW_VERSION"
echo

# Update VERSION file
echo "$NEW_VERSION" > "$VERSION_FILE"
echo "✓ Updated $VERSION_FILE"

# Update Helm Chart.yaml (when it exists)
CHART_FILE="$PROJECT_ROOT/charts/mock-device/Chart.yaml"
if [ -f "$CHART_FILE" ]; then
    sed -i "s/^version:.*/version: $NEW_VERSION/" "$CHART_FILE"
    sed -i "s/^appVersion:.*/appVersion: \"$NEW_VERSION\"/" "$CHART_FILE"
    echo "✓ Updated $CHART_FILE"
fi

# Update Helm values.yaml (when it exists)
VALUES_FILE="$PROJECT_ROOT/charts/mock-device/values.yaml"
if [ -f "$VALUES_FILE" ]; then
    sed -i "s/tag: v.*/tag: v$NEW_VERSION/" "$VALUES_FILE"
    echo "✓ Updated $VALUES_FILE"
fi

echo
echo "Version bumped to $NEW_VERSION"
echo
echo "Next steps:"
echo "  1. Update CHANGELOG.md with release notes"
echo "  2. Commit changes: git add -A && git commit -m 'chore: bump version to v$NEW_VERSION'"
echo "  3. Create tag: git tag -a v$NEW_VERSION -m 'Release v$NEW_VERSION'"
echo "  4. Push: git push origin main && git push origin v$NEW_VERSION"
