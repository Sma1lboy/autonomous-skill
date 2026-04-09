# Repo Changelog Skill

Generate end-user friendly release notes and changelogs by analyzing git diffs.

## Overview

This skill transforms your git commit history into clean, readable release notes suitable for:
- Slack updates to support teams
- Customer-facing changelogs
- Release documentation

## Key Features

- **Reads actual code diffs** - Not just commit messages
- **End-user focus** - No technical jargon, functions, or variables
- **Smart consolidation** - Eliminates flip-flop changes, merges related updates
- **Breaking change detection** - Automatically flags changes requiring action
- **Cross-platform** - Works on Windows, macOS, Linux
- **Multi-host support** - GitHub, Bitbucket, local git

## Installation

### Claude Code (Recommended)

**User-level (all projects):**
```bash
cp -r repo-changelog ~/.claude/skills/
```

**Project-level (single project):**
```bash
cp -r repo-changelog .claude/skills/
```

### Windows

```cmd
xcopy /E /I repo-changelog %USERPROFILE%\.claude\skills\repo-changelog
```

## File Structure

```
repo-changelog/
├── SKILL.md                    # Main skill definition
├── README.md                   # This file
├── HOW_TO_USE.md              # Usage examples
├── git_analyzer.py            # Cross-platform git operations
├── diff_parser.py             # Diff analysis and interpretation
├── change_consolidator.py     # Change merging and deduplication
├── changelog_formatter.py     # Markdown output formatting
├── breaking_change_detector.py # Breaking change identification
├── sample_input.json          # Example input
└── expected_output.json       # Example output
```

## Output Format

Changes are organized into these categories:

| Category | Description |
|----------|-------------|
| **New Features** | Brand new functionality |
| **Enhancements** | Improvements to existing features |
| **Bug Fixes** | Issues that were resolved |
| **Changes** | Modifications to behavior |
| **Breaking Changes** | Changes requiring user action |
| **Other Updates** | Miscellaneous updates |

## Example Output

```markdown
# Release Notes - v1.1.0

*Released: 2024-12-25*

## New Features
- Added dark mode toggle in settings
- New export to PDF option in reports

## Enhancements
- Improved loading speed when opening large files
- Search now finds partial matches

## Bug Fixes
- Fixed issue where login would fail on slow connections
- Resolved crash when uploading files over 10MB

## Breaking Changes
- Database format updated - run migration tool before upgrading

---

**Notes:**
- Dark mode requires display driver update on Windows 7
```

## How It Works

1. **Gather Commits** - Collects commits in the specified range
2. **Read Full Diffs** - Analyzes actual code changes (not just messages)
3. **Interpret Changes** - Translates technical changes to plain English
4. **Consolidate** - Merges related changes, removes flip-flops
5. **Categorize** - Assigns to appropriate buckets
6. **Format** - Generates clean markdown

## Requirements

- Git repository
- Python 3.7+
- No external dependencies

## Limitations

- Requires valid git repository
- Tags must exist if specified
- Very large diffs may be summarized
- Complex changes may need human refinement

## Version

1.0.0 - Initial release

## License

MIT
