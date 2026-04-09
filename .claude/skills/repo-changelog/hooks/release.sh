#!/usr/bin/env bash
#
# Release Script
# Creates a git tag and generates release notes in one step.
#
# Usage:
#   ./release.sh v1.2.0
#   ./release.sh v1.2.0 "Release description message"
#
# Features:
#   - Creates annotated git tag
#   - Generates changelog from last tag to new tag
#   - Outputs to RELEASE_NOTES folder
#   - Cross-platform (works on Windows via Git Bash, macOS, Linux)
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Help message
show_help() {
    echo "Usage: $0 <version> [message]"
    echo ""
    echo "Arguments:"
    echo "  version    Version tag to create (e.g., v1.2.0)"
    echo "  message    Optional tag message (default: 'Release <version>')"
    echo ""
    echo "Examples:"
    echo "  $0 v1.2.0"
    echo "  $0 v1.2.0 'Major feature release'"
    echo ""
    echo "Options:"
    echo "  --help, -h     Show this help message"
    echo "  --dry-run      Show what would be done without doing it"
    echo "  --no-changelog Don't generate changelog"
}

# Parse arguments
DRY_RUN=false
NO_CHANGELOG=false
VERSION=""
MESSAGE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            show_help
            exit 0
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --no-changelog)
            NO_CHANGELOG=true
            shift
            ;;
        -*)
            echo -e "${RED}Unknown option: $1${NC}"
            show_help
            exit 1
            ;;
        *)
            if [ -z "$VERSION" ]; then
                VERSION="$1"
            else
                MESSAGE="$1"
            fi
            shift
            ;;
    esac
done

# Validate version
if [ -z "$VERSION" ]; then
    echo -e "${RED}Error: Version is required.${NC}"
    show_help
    exit 1
fi

# Set default message
if [ -z "$MESSAGE" ]; then
    MESSAGE="Release $VERSION"
fi

# Check if we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo -e "${RED}Error: Not a git repository.${NC}"
    exit 1
fi

# Check if tag already exists
if git rev-parse "$VERSION" > /dev/null 2>&1; then
    echo -e "${RED}Error: Tag '$VERSION' already exists.${NC}"
    exit 1
fi

# Get previous tag
PREVIOUS_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo '')

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Release Script${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

echo -e "${YELLOW}Configuration:${NC}"
echo "  New version: $VERSION"
echo "  Previous tag: ${PREVIOUS_TAG:-'(none)'}"
echo "  Message: $MESSAGE"
echo ""

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}DRY RUN - no changes will be made${NC}"
    echo ""
    echo "Would execute:"
    echo "  1. git tag -a '$VERSION' -m '$MESSAGE'"
    if [ "$NO_CHANGELOG" = false ]; then
        if [ -n "$PREVIOUS_TAG" ]; then
            echo "  2. python3 generate_changelog.py --from $PREVIOUS_TAG --to $VERSION --version $VERSION"
        else
            echo "  2. python3 generate_changelog.py --since $VERSION^ --version $VERSION"
        fi
    fi
    exit 0
fi

# Create the tag
echo -e "${GREEN}Creating tag '$VERSION'...${NC}"
git tag -a "$VERSION" -m "$MESSAGE"
echo -e "${GREEN}✓ Tag created${NC}"
echo ""

# Generate changelog if not disabled
if [ "$NO_CHANGELOG" = false ]; then
    # Find generate_changelog.py
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [ -f "$SCRIPT_DIR/../generate_changelog.py" ]; then
        CHANGELOG_SCRIPT="$SCRIPT_DIR/../generate_changelog.py"
    elif [ -f ".claude/skills/repo-changelog/generate_changelog.py" ]; then
        CHANGELOG_SCRIPT=".claude/skills/repo-changelog/generate_changelog.py"
    elif [ -f "$HOME/.claude/skills/repo-changelog/generate_changelog.py" ]; then
        CHANGELOG_SCRIPT="$HOME/.claude/skills/repo-changelog/generate_changelog.py"
    else
        echo -e "${YELLOW}Warning: Could not find generate_changelog.py${NC}"
        echo "Skipping changelog generation."
        CHANGELOG_SCRIPT=""
    fi

    if [ -n "$CHANGELOG_SCRIPT" ]; then
        echo -e "${GREEN}Generating release notes...${NC}"

        if [ -n "$PREVIOUS_TAG" ]; then
            python3 "$CHANGELOG_SCRIPT" --from "$PREVIOUS_TAG" --to "$VERSION" --version "$VERSION"
        else
            python3 "$CHANGELOG_SCRIPT" --last 100 --version "$VERSION"
        fi

        echo -e "${GREEN}✓ Release notes generated${NC}"
    fi
fi

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}  Release $VERSION complete!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Next steps:"
echo "  1. Review generated release notes in RELEASE_NOTES/"
echo "  2. Push the tag: git push origin $VERSION"
echo "  3. Create GitHub/Bitbucket release if desired"
