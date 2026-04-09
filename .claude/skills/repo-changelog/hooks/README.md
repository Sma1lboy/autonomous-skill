# Git Hooks for Repo-Changelog

This folder contains hook scripts for automating changelog generation when creating releases.

## Available Hooks

### 1. release.sh - Release Wrapper Script

The easiest way to create releases with automatic changelog generation.

**Usage:**
```bash
# Create a release with changelog
./hooks/release.sh v1.2.0

# With custom message
./hooks/release.sh v1.2.0 "Major feature release"

# Preview what would happen
./hooks/release.sh v1.2.0 --dry-run

# Just create tag, no changelog
./hooks/release.sh v1.2.0 --no-changelog
```

### 2. post-tag - Git Hook

A hook that triggers after tagging (requires manual setup since git doesn't have native post-tag support).

**Installation:**

1. Copy to .git/hooks:
```bash
cp hooks/post-tag .git/hooks/post-tag
chmod +x .git/hooks/post-tag
```

2. Create a git alias:
```bash
git config alias.release '!f() { git tag -a "$1" -m "${2:-Release $1}" && .git/hooks/post-tag "$1"; }; f'
```

3. Use the alias:
```bash
git release v1.2.0
git release v1.2.0 "Major feature release"
```

## Claude Code Integration

To integrate with Claude Code hooks, add this to your `.claude/settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "type": "command",
        "matcher": "Bash",
        "command": "python3 ~/.claude/skills/repo-changelog/generate_changelog.py --last 1 --stdout",
        "description": "Generate changelog for recent commits"
      }
    ]
  }
}
```

## Cross-Platform Notes

### Windows (Git Bash / WSL)
- All scripts work in Git Bash
- Use forward slashes in paths
- Make sure Python 3 is in PATH

### macOS / Linux
- Scripts work natively
- Ensure execute permission: `chmod +x *.sh`

## Troubleshooting

### "generate_changelog.py not found"

The scripts look for the changelog generator in these locations:
1. `./hooks/../generate_changelog.py` (relative to hook)
2. `.claude/skills/repo-changelog/generate_changelog.py` (project level)
3. `~/.claude/skills/repo-changelog/generate_changelog.py` (user level)

Make sure the skill is installed in one of these locations.

### "No previous tag found"

This is normal for the first release. The script will analyze all commits up to the new tag.

### Permission Denied

Make scripts executable:
```bash
chmod +x hooks/*.sh
chmod +x hooks/post-tag
```
