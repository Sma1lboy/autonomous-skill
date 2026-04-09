"""
Changelog formatter module.
Generates Slack-ready markdown output with proper headings,
bullet points, and optional footnotes.

Now uses config.yaml for all customizable settings.
Outputs to RELEASE_NOTES folder with timestamps.
Supports audience-specific formatting (end-users, developers, executives).
"""

import re
import os
from typing import Dict, List, Any, Optional
from datetime import datetime
from pathlib import Path

# Import config loader
try:
    from .config_loader import get_config
except ImportError:
    from config_loader import get_config

# Import audience profiles
try:
    from .audience_profiles import get_category_names, get_profile, get_term_replacements
except ImportError:
    from audience_profiles import get_category_names, get_profile, get_term_replacements


class ChangelogFormatter:
    """
    Formats consolidated changes into clean markdown for Slack and documentation.

    Features:
    - Category headings from config (New Features, Enhancements, Bug Fixes, etc.)
    - Brief bullet points
    - Optional footnotes for important notes
    - No technical jargon or secrets
    - Outputs to RELEASE_NOTES folder with timestamps
    - Configurable via config.yaml
    """

    def __init__(self, config_path: Optional[str] = None):
        """
        Initialize the formatter.

        Args:
            config_path: Optional path to custom config file
        """
        self.config = get_config(config_path)
        self.footnotes: List[str] = []

    def _get_category_config(self, category: str) -> Dict[str, Any]:
        """Get configuration for a category from config."""
        return self.config.get_category_config(category)

    def _get_sorted_categories(self, categories: List[str]) -> List[str]:
        """Sort categories by their configured order."""
        return sorted(
            categories,
            key=lambda c: self._get_category_config(c).get('order', 99)
        )

    def format_changelog(self, grouped_changes: Dict[str, List[Dict[str, Any]]],
                         version: Optional[str] = None,
                         release_date: Optional[str] = None,
                         footnotes: Optional[List[str]] = None,
                         audience: str = 'end-users',
                         stats: Optional[Dict[str, Any]] = None) -> str:
        """
        Format changes into a complete changelog markdown.

        Args:
            grouped_changes: Changes grouped by category
            version: Optional version string (e.g., "v1.1.0")
            release_date: Optional release date
            footnotes: Optional list of footnote strings
            audience: Target audience ('end-users', 'developers', 'executives')
            stats: Optional statistics dictionary

        Returns:
            Formatted markdown string
        """
        # Use executive format for executives
        if audience == 'executives':
            return self._format_executive_summary(grouped_changes, version, stats)

        lines = []

        # Header
        header = self._format_header(version, release_date)
        if header:
            lines.append(header)
            lines.append('')

        # Get audience-specific category names
        category_names = get_category_names(audience)

        # Sort categories by order from config
        sorted_categories = self._get_sorted_categories(list(grouped_changes.keys()))

        # Check for excluded categories
        exclude = self.config.get('filters', 'exclude_categories', default=[])

        # Format each category
        for category in sorted_categories:
            if category in exclude:
                continue

            changes = grouped_changes.get(category, [])
            if not changes:
                continue

            section = self._format_category_section(category, changes, audience, category_names)
            if section:
                lines.append(section)
                lines.append('')

        # Add footnotes if provided
        if footnotes:
            footnote_section = self._format_footnotes(footnotes)
            lines.append(footnote_section)

        return '\n'.join(lines)

    def _format_header(self, version: Optional[str],
                       release_date: Optional[str]) -> str:
        """Format the changelog header."""
        if version:
            header = f"# Release Notes - {version}"
        else:
            header = "# Release Notes"

        include_date = self.config.get('output', 'include_date_header', default=True)

        if include_date:
            if release_date:
                header += f"\n\n*Released: {release_date}*"
            else:
                date_format = self.config.get('output', 'header_date_format', default='%Y-%m-%d')
                today = datetime.now().strftime(date_format)
                header += f"\n\n*Released: {today}*"

        return header

    def _format_category_section(self, category: str,
                                  changes: List[Dict[str, Any]],
                                  audience: str = 'end-users',
                                  category_names: Optional[Dict[str, str]] = None) -> str:
        """Format a single category section."""
        cat_config = self._get_category_config(category)

        lines = []

        # Section heading - use audience-specific names if available
        if category_names and category in category_names:
            heading = category_names[category]
        else:
            heading = cat_config.get('heading', category.title())
        lines.append(f"## {heading}")
        lines.append('')

        # Apply max per category limit if configured
        max_items = self.config.get('consolidation', 'max_per_category', default=0)
        display_changes = changes if max_items == 0 else changes[:max_items]

        # Bullet points
        for change in display_changes:
            bullet = self._format_bullet_point(change, audience)
            if bullet:
                lines.append(bullet)

        # Show overflow count if limited
        if max_items > 0 and len(changes) > max_items:
            lines.append(f"- _...and {len(changes) - max_items} more_")

        return '\n'.join(lines)

    def _format_bullet_point(self, change: Dict[str, Any],
                              audience: str = 'end-users') -> str:
        """Format a single change as a bullet point."""
        description = change.get('description', '')

        if not description:
            return ''

        # Clean up the description
        description = self._clean_description(description)

        # Apply term replacements for end-users
        if audience == 'end-users':
            description = self._apply_term_replacements(description)

        # Format as bullet point
        return f"- {description}"

    def _apply_term_replacements(self, text: str) -> str:
        """Replace technical terms with user-friendly language."""
        replacements = get_term_replacements()
        for pattern, replacement in replacements.items():
            text = re.sub(pattern, replacement, text, flags=re.IGNORECASE)
        return text

    def _format_executive_summary(self, grouped_changes: Dict[str, List[Dict[str, Any]]],
                                   version: Optional[str] = None,
                                   stats: Optional[Dict[str, Any]] = None) -> str:
        """Format changes as an executive summary."""
        lines = []

        # Header
        if version:
            lines.append(f"## Release Summary - {version}")
        else:
            lines.append("## Release Summary")
        lines.append('')

        category_names = get_category_names('executives')

        # Aggregate counts by business category
        business_categories = {
            'New Capabilities': [],
            'Improvements': [],
            'Stability & Fixes': [],
            'Security Updates': [],
            'Important Changes': [],
        }

        for category, changes in grouped_changes.items():
            display_name = category_names.get(category, category.title())
            if display_name in business_categories:
                business_categories[display_name].extend(changes)

        # Format each business category with counts
        for biz_cat, changes in business_categories.items():
            if not changes:
                continue

            count = len(changes)
            if count == 1:
                # Show single item description
                desc = changes[0].get('description', '')
                if desc and desc != 'INTERNAL_ONLY':
                    desc = self._clean_description(desc)[:60]
                    lines.append(f"**{biz_cat}**: {desc}")
            else:
                # Show count and summary
                lines.append(f"**{biz_cat}** ({count})")

        lines.append('')

        # Add overall stats if available
        if stats:
            total_commits = stats.get('total_commits', 0)
            total_changes = stats.get('total_changes', 0)
            if total_commits or total_changes:
                lines.append(f"*{total_changes} changes from {total_commits} commits*")

        return '\n'.join(lines)

    def _clean_description(self, description: str) -> str:
        """Clean and format a description for output."""
        # Ensure proper capitalization
        if description and description[0].islower():
            description = description[0].upper() + description[1:]

        # Remove trailing punctuation except for question marks
        description = description.rstrip('.,;:')

        # Ensure single line
        description = description.replace('\n', ' ').strip()

        # Remove any remaining technical artifacts
        description = self._remove_technical_artifacts(description)

        return description

    def _remove_technical_artifacts(self, text: str) -> str:
        """Remove technical artifacts from text."""
        # Remove file paths
        text = re.sub(r'/[\w/.-]+\.\w+', '', text)

        # Remove Windows paths
        text = re.sub(r'[A-Z]:\\[\w\\.-]+', '', text)

        # Remove git hashes
        text = re.sub(r'\b[a-f0-9]{7,40}\b', '', text)

        # Remove URLs but keep the description
        text = re.sub(r'https?://\S+', '', text)

        # Remove extra whitespace
        text = ' '.join(text.split())

        return text

    def _format_footnotes(self, footnotes: List[str]) -> str:
        """Format footnotes section."""
        lines = ['---', '', '**Notes:**']

        for note in footnotes:
            # Filter out any notes that might contain secrets
            if self._contains_sensitive_info(note):
                continue
            lines.append(f"- {note}")

        return '\n'.join(lines)

    def _contains_sensitive_info(self, text: str) -> bool:
        """Check if text contains potentially sensitive information."""
        sensitive_patterns = [
            r'password\s*[:=]',
            r'secret\s*[:=]',
            r'api[_-]?key\s*[:=]',
            r'token\s*[:=]',
            r'auth\s*[:=]',
            r'\b[A-Za-z0-9+/]{40,}\b',  # Long base64-like strings
            r'Bearer\s+\S+',  # Bearer tokens
            r'Basic\s+\S+',  # Basic auth
        ]

        text_lower = text.lower()
        for pattern in sensitive_patterns:
            if re.search(pattern, text_lower, re.IGNORECASE):
                return True

        return False

    def format_slack_message(self, grouped_changes: Dict[str, List[Dict[str, Any]]],
                              version: Optional[str] = None,
                              summary: Optional[str] = None,
                              audience: str = 'end-users') -> str:
        """
        Format changes as a Slack-friendly message.

        Similar to changelog but more concise for Slack's format.

        Args:
            grouped_changes: Changes grouped by category
            version: Optional version string
            audience: Target audience
            summary: Optional one-line summary

        Returns:
            Slack-formatted markdown string
        """
        lines = []

        # Get Slack config
        max_items = self.config.get('slack', 'max_items_per_category', default=5)
        show_overflow = self.config.get('slack', 'show_overflow_count', default=True)

        # Header for Slack
        if version:
            lines.append(f"*Release {version} is now available!*")
        else:
            lines.append("*New Release Available!*")

        if summary:
            lines.append(f"_{summary}_")

        lines.append('')

        # Sort and format categories
        sorted_categories = self._get_sorted_categories(list(grouped_changes.keys()))

        for category in sorted_categories:
            changes = grouped_changes.get(category, [])
            if not changes:
                continue

            # Category header (bold for Slack)
            cat_config = self._get_category_config(category)
            lines.append(f"*{cat_config.get('heading', category.title())}*")

            # Limit items for Slack
            for change in changes[:max_items]:
                description = self._clean_description(change.get('description', ''))
                if description:
                    lines.append(f"• {description}")

            if show_overflow and len(changes) > max_items:
                lines.append(f"  _...and {len(changes) - max_items} more_")

            lines.append('')

        return '\n'.join(lines)

    def format_simple_list(self, grouped_changes: Dict[str, List[Dict[str, Any]]],
                            audience: str = 'end-users') -> str:
        """
        Format changes as a simple bulleted list without headings.
        Useful for quick updates or small releases.

        Args:
            grouped_changes: Changes grouped by category
            audience: Target audience

        Returns:
            Simple bullet list
        """
        lines = []

        # Flatten all changes in order
        all_changes = []
        sorted_categories = self._get_sorted_categories(list(grouped_changes.keys()))

        for category in sorted_categories:
            all_changes.extend(grouped_changes.get(category, []))

        for change in all_changes:
            description = self._clean_description(change.get('description', ''))
            if description:
                lines.append(f"- {description}")

        return '\n'.join(lines)

    def ensure_output_directory(self, base_path: Optional[str] = None) -> Path:
        """
        Ensure the output directory exists.

        Args:
            base_path: Base path for output (default: current directory)

        Returns:
            Path to output directory
        """
        output_dir = self.config.get('output', 'directory', default='RELEASE_NOTES')

        if base_path:
            full_path = Path(base_path) / output_dir
        else:
            full_path = Path.cwd() / output_dir

        # Create directory if it doesn't exist
        full_path.mkdir(parents=True, exist_ok=True)

        return full_path

    def generate_filename(self, version: Optional[str] = None,
                          base_path: Optional[str] = None) -> str:
        """
        Generate a full file path for the changelog with timestamp.

        Args:
            version: Optional version string
            base_path: Base path for output (default: current directory)

        Returns:
            Full path to output file
        """
        # Ensure output directory exists
        output_dir = self.ensure_output_directory(base_path)

        # Get datetime format from config
        dt_format = self.config.get('output', 'datetime_format', default='%Y%m%d_%H%M%S')
        timestamp = datetime.now().strftime(dt_format)

        if version:
            # Clean version string for filename
            clean_version = re.sub(r'[^\w.-]', '', version)
            filename_template = self.config.get(
                'output', 'filename_format',
                default='RELEASE_NOTES_{version}_{datetime}.md'
            )
            filename = filename_template.format(
                version=clean_version,
                datetime=timestamp,
                date=datetime.now().strftime('%Y%m%d')
            )
        else:
            filename_template = self.config.get(
                'output', 'filename_format_no_version',
                default='RELEASE_NOTES_{datetime}.md'
            )
            filename = filename_template.format(
                datetime=timestamp,
                date=datetime.now().strftime('%Y%m%d')
            )

        return str(output_dir / filename)

    def save_to_file(self, content: str, file_path: Optional[str] = None,
                     version: Optional[str] = None,
                     base_path: Optional[str] = None) -> str:
        """
        Save formatted content to a markdown file.

        Args:
            content: Formatted markdown content
            file_path: Explicit file path (overrides auto-generation)
            version: Version for auto-generated filename
            base_path: Base path for output directory

        Returns:
            Path to saved file

        Raises:
            IOError: If file cannot be written
        """
        # Use provided path or generate one
        if file_path:
            output_path = Path(file_path)
            # Ensure parent directory exists
            output_path.parent.mkdir(parents=True, exist_ok=True)
        else:
            output_path = Path(self.generate_filename(version, base_path))

        try:
            with open(output_path, 'w', encoding='utf-8') as f:
                f.write(content)
            return str(output_path)
        except Exception as e:
            raise IOError(f"Failed to write file {output_path}: {e}")

    def append_to_changelog(self, new_content: str,
                            changelog_path: Optional[str] = None,
                            create_backup: bool = True) -> str:
        """
        Prepend new release notes to existing CHANGELOG.md.

        Args:
            new_content: New release notes content
            changelog_path: Path to CHANGELOG.md (default from config)
            create_backup: Create backup before modifying

        Returns:
            Path to modified changelog

        Raises:
            FileNotFoundError: If changelog doesn't exist
            IOError: If file cannot be modified
        """
        # Get default changelog path from config
        if not changelog_path:
            changelog_path = self.config.get(
                'changelog_append', 'default_file',
                default='CHANGELOG.md'
            )

        changelog = Path(changelog_path)

        if not changelog.exists():
            raise FileNotFoundError(f"Changelog not found: {changelog_path}")

        # Create backup if requested
        if create_backup:
            backup_suffix = self.config.get(
                'changelog_append', 'backup_suffix',
                default='.bak'
            )
            backup_path = changelog.with_suffix(changelog.suffix + backup_suffix)
            with open(changelog, 'r', encoding='utf-8') as f:
                backup_content = f.read()
            with open(backup_path, 'w', encoding='utf-8') as f:
                f.write(backup_content)

        # Read existing content
        with open(changelog, 'r', encoding='utf-8') as f:
            existing_content = f.read()

        # Find insertion point (after header, before first version)
        insert_pattern = self.config.get(
            'changelog_append', 'insert_after_pattern',
            default=r'^## \['
        )

        match = re.search(insert_pattern, existing_content, re.MULTILINE)

        if match:
            # Insert before the first version section
            insert_pos = match.start()
            new_full_content = (
                existing_content[:insert_pos] +
                new_content + '\n\n' +
                existing_content[insert_pos:]
            )
        else:
            # No existing versions found, append after header
            header_pattern = self.config.get(
                'changelog_append', 'header_pattern',
                default=r'^# Changelog'
            )
            header_match = re.search(header_pattern, existing_content, re.MULTILINE)

            if header_match:
                # Find end of header section (next blank line)
                header_end = existing_content.find('\n\n', header_match.end())
                if header_end == -1:
                    header_end = len(existing_content)
                else:
                    header_end += 2  # Include the blank line

                new_full_content = (
                    existing_content[:header_end] +
                    '\n' + new_content + '\n' +
                    existing_content[header_end:]
                )
            else:
                # No header found, prepend everything
                new_full_content = new_content + '\n\n' + existing_content

        # Write updated content
        with open(changelog, 'w', encoding='utf-8') as f:
            f.write(new_full_content)

        return str(changelog)
