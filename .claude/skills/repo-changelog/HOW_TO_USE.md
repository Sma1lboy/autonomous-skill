# How to Use This Skill

Hey Claude—I just added the "repo-changelog" skill. Can you generate release notes for what changed since our last release?

## Example Invocations

### Generate Release Notes Between Tags

**Example 1 - Between two versions:**
```
Hey Claude—I just added the "repo-changelog" skill.
Can you generate release notes from v1.0.0 to v1.1.0?
```

**Example 2 - Since last release:**
```
Hey Claude—I just added the "repo-changelog" skill.
What changed since v2.3.0? Format it for our Slack support channel.
```

### Recent Commits

**Example 3 - Last 30 commits:**
```
Hey Claude—I just added the "repo-changelog" skill.
Show me what changed in the last 30 commits, ready for our changelog.
```

**Example 4 - Quick update:**
```
Hey Claude—I just added the "repo-changelog" skill.
Give me a quick summary of recent changes for Slack.
```

### Specific Repository

**Example 5 - Different repository:**
```
Hey Claude—I just added the "repo-changelog" skill.
Generate release notes for C:\Projects\MyApp from tag release-2024-01 to HEAD.
```

## What to Provide

- **Repository path** (optional): Defaults to current directory
- **Version range**: Either two tags, a single tag (since that tag), or "last N commits"
- **Output preference** (optional): Full changelog or Slack-ready format

## What You'll Get

A markdown file with:

```markdown
# Release Notes - v1.1.0

*Released: 2024-12-25*

## New Features
- Added dark mode toggle in settings
- New export to PDF option

## Enhancements
- Improved loading speed for large files
- Better error messages

## Bug Fixes
- Fixed login issue on slow connections
- Resolved crash when uploading large files

## Changes
- Settings menu reorganized
- Default format changed to Excel

## Breaking Changes
- Database format updated - run migration tool before upgrading

---

**Notes:**
- Dark mode requires display driver update on Windows 7
```

## Tips

1. **Use clear version tags**: Tags like `v1.0.0` or `release-2024-01` work best
2. **Review the output**: AI interpretation is good but human review ensures accuracy
3. **Add footnotes**: If there are setup steps, mention them in your request
4. **For Slack**: Ask for "Slack format" to get a more concise version

## Windows Users

All commands work on Windows. Use paths like:
```
C:\Users\YourName\Projects\MyApp
```

## Supported Git Hosts

- GitHub
- Bitbucket
- Local git repositories
