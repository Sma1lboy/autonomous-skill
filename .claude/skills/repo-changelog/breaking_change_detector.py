"""
Breaking change detector module.
Identifies breaking changes from commit messages and code diffs.

Now uses config.yaml for customizable patterns and keywords.
"""

import re
from typing import Dict, List, Any, Optional

# Import config loader
try:
    from .config_loader import get_config
except ImportError:
    from config_loader import get_config


class BreakingChangeDetector:
    """
    Detects breaking changes from multiple sources:
    - Commit message keywords (BREAKING, !:)
    - Conventional commit syntax
    - Removed features in diffs
    - Configuration changes that require action

    All settings configurable via config.yaml.
    """

    # Default commit message patterns indicating breaking changes
    DEFAULT_COMMIT_PATTERNS = [
        r'BREAKING\s*CHANGE',
        r'BREAKING:',
        r'BREAKING\s*-',
        r'^.+!:',  # Conventional commit with ! (e.g., feat!:, fix!:)
        r'\[BREAKING\]',
        r'⚠️\s*BREAKING',
    ]

    # Default keywords that often indicate breaking changes
    DEFAULT_KEYWORDS = [
        'breaking',
        'migrate',
        'migration required',
        'manual update',
        'update required',
        'action required',
        'must update',
        'incompatible',
        'deprecated and removed',
        'no longer supported',
        'removed support',
        'requires upgrade',
        'database migration',
        'schema change',
    ]

    # Default patterns in diffs that may indicate breaking changes
    DEFAULT_DIFF_PATTERNS = [
        # Removed exports/public APIs
        (r'^-\s*export\s+(function|class|const)\s+\w+', 'Removed exported functionality'),
        (r'^-\s*public\s+(function|void|int|string)', 'Removed public method'),

        # Removed endpoints
        (r'^-\s*@(Get|Post|Put|Delete|Patch)\s*\(', 'Removed API endpoint'),
        (r'^-\s*router\.(get|post|put|delete|patch)\s*\(', 'Removed API route'),

        # Removed configuration options
        (r'^-\s*["\'](\w+)["\']:\s*{', 'Removed configuration option'),

        # Changed database schemas
        (r'DROP\s+(TABLE|COLUMN|INDEX)', 'Database schema change - data may be affected'),
        (r'ALTER\s+TABLE.*DROP', 'Database column removed'),

        # Removed feature flags
        (r'^-\s*(feature|flag).*enabled', 'Feature flag removed'),
    ]

    def __init__(self, config_path: Optional[str] = None):
        """
        Initialize the detector.

        Args:
            config_path: Optional path to custom config file
        """
        self.config = get_config(config_path)
        self.breaking_changes: List[Dict[str, Any]] = []

        # Load settings from config
        self.detect_from_diff = self.config.get(
            'breaking_changes', 'detect_from_diff', default=True
        )
        self.breaking_indicator = self.config.get(
            'breaking_changes', 'conventional_breaking_indicator', default='!'
        )

        # Load keywords from config, falling back to defaults
        self.commit_keywords = self.config.get(
            'breaking_changes', 'commit_keywords', default=self.DEFAULT_KEYWORDS
        )

        # Load diff patterns from config if available
        diff_patterns_config = self.config.get(
            'breaking_changes', 'diff_patterns', default=None
        )
        if diff_patterns_config:
            # Convert config list to tuple format
            self.diff_patterns = [
                (p, 'Breaking change detected') for p in diff_patterns_config
            ]
        else:
            self.diff_patterns = self.DEFAULT_DIFF_PATTERNS

    def detect(self, subject: str, body: str = '', diff: str = '') -> List[Dict[str, Any]]:
        """
        Detect breaking changes from a single commit.

        This is a convenience method for single-commit analysis.

        Args:
            subject: Commit subject line
            body: Commit body (optional)
            diff: Diff content (optional)

        Returns:
            List of breaking change dictionaries
        """
        # Create a pseudo-commit dict for internal methods
        commit = {
            'subject': subject,
            'body': body,
            'short_hash': '',
            'hash': 'single'
        }

        breaking = []

        # Check commit message
        message_breaks = self._check_commit_message(commit)
        breaking.extend(message_breaks)

        # Check commit body for BREAKING CHANGE footer
        if body:
            body_breaks = self._check_commit_body(commit)
            breaking.extend(body_breaks)

        # Check diff if provided and enabled in config
        if diff and self.detect_from_diff:
            diff_breaks = self._check_diff(diff, commit)
            breaking.extend(diff_breaks)

        # Add category for consolidation
        for change in breaking:
            change['category'] = 'breaking'

        return self._deduplicate(breaking)

    def detect_from_commits(self, commits: List[Dict[str, Any]],
                            diffs: Optional[Dict[str, str]] = None) -> List[Dict[str, Any]]:
        """
        Detect breaking changes from multiple commits.

        Args:
            commits: List of commit dictionaries
            diffs: Optional dictionary mapping commit hash to diff content

        Returns:
            List of breaking change descriptions
        """
        self.breaking_changes = []

        for commit in commits:
            # Check commit message
            message_breaks = self._check_commit_message(commit)
            self.breaking_changes.extend(message_breaks)

            # Check commit body for BREAKING CHANGE footer
            body_breaks = self._check_commit_body(commit)
            self.breaking_changes.extend(body_breaks)

            # Check diff if provided and enabled
            if self.detect_from_diff and diffs and commit.get('hash') in diffs:
                diff_breaks = self._check_diff(diffs[commit['hash']], commit)
                self.breaking_changes.extend(diff_breaks)

        # Add category for consolidation
        for change in self.breaking_changes:
            change['category'] = 'breaking'

        # Deduplicate
        return self._deduplicate(self.breaking_changes)

    def _check_commit_message(self, commit: Dict[str, Any]) -> List[Dict[str, Any]]:
        """Check commit subject for breaking change indicators."""
        subject = commit.get('subject', '')
        if not subject:
            return []

        breaking = []

        # Check for explicit breaking patterns
        for pattern in self.DEFAULT_COMMIT_PATTERNS:
            if re.search(pattern, subject, re.IGNORECASE):
                description = self._extract_breaking_description(subject)
                breaking.append({
                    'description': description,
                    'source': 'commit_message',
                    'commit': commit.get('short_hash', ''),
                    'confidence': 'high'
                })
                break  # Only add once per commit

        # Check for keywords if not already found
        if not breaking:
            subject_lower = subject.lower()
            for keyword in self.commit_keywords:
                if keyword in subject_lower:
                    description = self._extract_breaking_description(subject)
                    breaking.append({
                        'description': description,
                        'source': 'commit_keyword',
                        'commit': commit.get('short_hash', ''),
                        'confidence': 'medium'
                    })
                    break

        return breaking

    def _check_commit_body(self, commit: Dict[str, Any]) -> List[Dict[str, Any]]:
        """Check commit body for BREAKING CHANGE footer."""
        body = commit.get('body', '')
        if not body:
            return []

        breaking = []

        # Look for conventional commit BREAKING CHANGE footer
        match = re.search(r'BREAKING\s*CHANGE[S]?\s*:\s*(.+?)(?:\n\n|$)',
                          body, re.IGNORECASE | re.DOTALL)

        if match:
            description = match.group(1).strip()
            # Clean up multi-line descriptions
            description = ' '.join(description.split())
            description = self._humanize_breaking_change(description)

            breaking.append({
                'description': description,
                'source': 'commit_body',
                'commit': commit.get('short_hash', ''),
                'confidence': 'high'
            })

        return breaking

    def _check_diff(self, diff_content: str,
                    commit: Dict[str, Any]) -> List[Dict[str, Any]]:
        """Check diff content for potential breaking changes."""
        if not diff_content:
            return []

        breaking = []

        for line in diff_content.split('\n'):
            for pattern, description_template in self.diff_patterns:
                if re.search(pattern, line, re.IGNORECASE):
                    breaking.append({
                        'description': description_template,
                        'source': 'diff_analysis',
                        'commit': commit.get('short_hash', ''),
                        'confidence': 'low',
                        'raw': line.strip()[:100]  # First 100 chars
                    })
                    break  # Only match one pattern per line

        return breaking

    def _extract_breaking_description(self, message: str) -> str:
        """Extract a clean description from a breaking change message."""
        # Remove breaking prefixes
        clean = message

        # Remove conventional commit prefix
        clean = re.sub(r'^.+!:\s*', '', clean)

        # Remove BREAKING prefix
        clean = re.sub(r'BREAKING[\s:-]*', '', clean, flags=re.IGNORECASE)
        clean = re.sub(r'\[BREAKING\]\s*', '', clean, flags=re.IGNORECASE)

        # Clean up
        clean = clean.strip()

        # Humanize the description
        clean = self._humanize_breaking_change(clean)

        return clean

    def _humanize_breaking_change(self, description: str) -> str:
        """Convert technical breaking change to user-friendly description."""
        if not description:
            return "Action may be required for this update"

        # Ensure proper capitalization
        if description and description[0].islower():
            description = description[0].upper() + description[1:]

        # Replace technical terms
        replacements = [
            (r'\bapi\b', 'system', re.IGNORECASE),
            (r'\bendpoint\b', 'feature', re.IGNORECASE),
            (r'\bdeprecated\b', 'removed', re.IGNORECASE),
            (r'\bschema\b', 'data format', re.IGNORECASE),
            (r'\bconfig(?:uration)?\b', 'settings', re.IGNORECASE),
            (r'\benv(?:ironment)?\s*var(?:iable)?s?\b', 'settings', re.IGNORECASE),
        ]

        for pattern, replacement, flags in replacements:
            description = re.sub(pattern, replacement, description, flags=flags)

        # Add action prefix if not present
        action_words = ['must', 'need', 'require', 'update', 'change', 'run', 'execute']
        has_action = any(word in description.lower() for word in action_words)

        if not has_action and len(description) < 100:
            # Add "may require action" if no action word present
            description = f"{description} - please review before upgrading"

        return description

    def _deduplicate(self, breaking_changes: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        """Remove duplicate breaking changes."""
        seen = set()
        unique = []

        for change in breaking_changes:
            # Create a key from description (normalized)
            key = change['description'].lower().strip()

            if key not in seen:
                seen.add(key)
                unique.append(change)

        # Sort by confidence (high first)
        confidence_order = {'high': 0, 'medium': 1, 'low': 2}
        unique.sort(key=lambda x: confidence_order.get(x.get('confidence', 'low'), 99))

        return unique

    def get_user_action_items(self, breaking_changes: List[Dict[str, Any]]) -> List[str]:
        """
        Extract actionable items from breaking changes.

        Returns a list of things users need to do before/after upgrading.
        """
        actions = []

        for change in breaking_changes:
            desc = change.get('description', '')
            source = change.get('source', '')

            # Only high/medium confidence changes
            if change.get('confidence') == 'low':
                continue

            # Extract or generate action
            if 'database' in desc.lower() or 'schema' in desc.lower() or 'data format' in desc.lower():
                actions.append("Back up your data before upgrading")
                actions.append("Run database migration after upgrade")
            elif 'settings' in desc.lower() or 'config' in desc.lower():
                actions.append("Review and update your settings after upgrade")
            elif 'removed' in desc.lower():
                actions.append("Check if you use any removed features")

        # Deduplicate actions
        return list(dict.fromkeys(actions))

    def summarize(self, breaking_changes: List[Dict[str, Any]]) -> str:
        """
        Create a summary of breaking changes for the changelog header.
        """
        if not breaking_changes:
            return ""

        high_confidence = [c for c in breaking_changes if c.get('confidence') == 'high']
        count = len(breaking_changes)

        if count == 1:
            return "This release contains 1 breaking change - please review before upgrading."
        elif high_confidence:
            return f"This release contains {count} breaking changes - please review before upgrading."
        else:
            return f"This release may contain changes that require attention - please review before upgrading."
