"""
Preview mode for changelog generation.
Allows users to review, edit, and confirm changes before saving.

Provides an interactive terminal interface with:
- Paginated change display
- Edit/remove individual changes
- Category reorganization
- Final confirmation before save
"""

import sys
import os
from typing import Dict, List, Any, Optional, Tuple
from pathlib import Path

# Import config loader
try:
    from .config_loader import get_config
except ImportError:
    from config_loader import get_config


class PreviewMode:
    """
    Interactive preview mode for changelog changes.

    Features:
    - Display changes with line numbers
    - Allow editing descriptions
    - Allow removing changes
    - Reorganize categories
    - Confirm before saving
    - Color output support (when enabled)
    """

    # ANSI color codes
    COLORS = {
        'header': '\033[1;36m',      # Cyan bold
        'category': '\033[1;33m',    # Yellow bold
        'number': '\033[0;90m',      # Gray
        'item': '\033[0m',           # Reset
        'highlight': '\033[1;32m',   # Green bold
        'warning': '\033[1;31m',     # Red bold
        'prompt': '\033[1;35m',      # Magenta bold
        'reset': '\033[0m'           # Reset
    }

    def __init__(self, config: Optional[Any] = None, config_path: Optional[str] = None):
        """
        Initialize preview mode.

        Args:
            config: Optional ConfigLoader instance
            config_path: Optional path to custom config file
        """
        if config:
            self.config = config
        else:
            self.config = get_config(config_path)

        # Load settings from config
        self.use_colors = self.config.get('preview', 'use_colors', default=True)
        self.show_line_numbers = self.config.get('preview', 'show_line_numbers', default=True)
        self.items_per_page = self.config.get('preview', 'items_per_page', default=20)
        self.confirm_save = self.config.get('preview', 'confirm_save', default=True)

        # Disable colors if terminal doesn't support them
        if not self._supports_color():
            self.use_colors = False

    def _supports_color(self) -> bool:
        """Check if terminal supports color output."""
        # Check for common environment indicators
        if os.environ.get('NO_COLOR'):
            return False
        if os.environ.get('TERM') == 'dumb':
            return False
        # Windows cmd.exe doesn't support ANSI by default
        if os.name == 'nt':
            return os.environ.get('ANSICON') or 'xterm' in os.environ.get('TERM', '')
        return hasattr(sys.stdout, 'isatty') and sys.stdout.isatty()

    def _color(self, text: str, color_name: str) -> str:
        """Apply color to text if colors are enabled."""
        if not self.use_colors:
            return text
        color = self.COLORS.get(color_name, '')
        reset = self.COLORS.get('reset', '')
        return f"{color}{text}{reset}"

    def preview_and_confirm(self, result: Dict[str, Any]) -> bool:
        """
        Display preview and get user confirmation.

        Args:
            result: Result dictionary from ChangelogGenerator.generate()

        Returns:
            True if user confirms, False if cancelled
        """
        changes = result.get('changes', [])
        grouped = result.get('grouped', {})
        stats = result.get('stats', {})

        if not changes:
            print(self._color("No changes to preview.", 'warning'))
            return False

        # Display header
        self._print_header(stats)

        # Display changes by category
        self._display_changes(grouped)

        # Interactive editing loop
        while True:
            action = self._prompt_action()

            if action == 'c':  # Confirm
                return True
            elif action == 'q':  # Quit/Cancel
                return False
            elif action == 'e':  # Edit
                self._edit_mode(grouped)
            elif action == 'r':  # Remove
                self._remove_mode(grouped)
            elif action == 'v':  # View again
                self._display_changes(grouped)
            elif action == 'h':  # Help
                self._show_help()

    def _print_header(self, stats: Dict[str, Any]) -> None:
        """Print preview header with statistics."""
        print()
        print(self._color("=" * 60, 'header'))
        print(self._color("  CHANGELOG PREVIEW", 'header'))
        print(self._color("=" * 60, 'header'))
        print()

        total_commits = stats.get('total_commits', 0)
        total_changes = stats.get('total_changes', 0)

        print(f"  Commits analyzed: {self._color(str(total_commits), 'highlight')}")
        print(f"  Changes detected: {self._color(str(total_changes), 'highlight')}")
        print()

        # Show breakdown by category
        by_category = stats.get('by_category', {})
        if by_category:
            print("  By category:")
            for cat, count in sorted(by_category.items()):
                cat_config = self.config.get_category_config(cat)
                heading = cat_config.get('heading', cat.title())
                print(f"    - {heading}: {count}")
        print()

    def _display_changes(self, grouped: Dict[str, List[Dict[str, Any]]]) -> None:
        """Display changes grouped by category."""
        # Get sorted categories
        sorted_cats = self.config.get_sorted_categories()
        available_cats = [c for c in sorted_cats if c in grouped]

        line_number = 1

        for category in available_cats:
            changes = grouped.get(category, [])
            if not changes:
                continue

            # Category header
            cat_config = self.config.get_category_config(category)
            heading = cat_config.get('heading', category.title())
            print(self._color(f"\n## {heading}", 'category'))
            print()

            # Changes
            for change in changes:
                desc = change.get('description', '')
                confidence = change.get('confidence', 'medium')

                if self.show_line_numbers:
                    num_str = f"[{line_number:2d}]"
                    print(f"  {self._color(num_str, 'number')} - {desc}")
                else:
                    print(f"  - {desc}")

                line_number += 1

        print()

    def _prompt_action(self) -> str:
        """Prompt user for action."""
        print(self._color("-" * 40, 'prompt'))
        print(self._color("Actions:", 'prompt'))
        print("  [c]onfirm  - Save and generate changelog")
        print("  [q]uit     - Cancel without saving")
        print("  [e]dit     - Edit a change")
        print("  [r]emove   - Remove a change")
        print("  [v]iew     - View changes again")
        print("  [h]elp     - Show more options")
        print()

        try:
            response = input(self._color("Choose action: ", 'prompt')).strip().lower()
            return response[:1] if response else ''
        except (EOFError, KeyboardInterrupt):
            return 'q'

    def _edit_mode(self, grouped: Dict[str, List[Dict[str, Any]]]) -> None:
        """Enter edit mode to modify a change."""
        # Build flat list with references
        all_changes = self._get_flat_list(grouped)

        if not all_changes:
            print(self._color("No changes to edit.", 'warning'))
            return

        try:
            num_str = input(self._color("Enter line number to edit (or 'c' to cancel): ", 'prompt')).strip()
            if num_str.lower() == 'c':
                return

            num = int(num_str)
            if num < 1 or num > len(all_changes):
                print(self._color(f"Invalid line number. Must be 1-{len(all_changes)}", 'warning'))
                return

            change, category = all_changes[num - 1]
            current_desc = change.get('description', '')

            print(f"\nCurrent: {current_desc}")
            new_desc = input(self._color("New description (or 'c' to cancel): ", 'prompt')).strip()

            if new_desc.lower() != 'c' and new_desc:
                change['description'] = new_desc
                print(self._color("Updated!", 'highlight'))

        except ValueError:
            print(self._color("Invalid input.", 'warning'))
        except (EOFError, KeyboardInterrupt):
            print()

    def _remove_mode(self, grouped: Dict[str, List[Dict[str, Any]]]) -> None:
        """Enter remove mode to delete a change."""
        # Build flat list with references
        all_changes = self._get_flat_list(grouped)

        if not all_changes:
            print(self._color("No changes to remove.", 'warning'))
            return

        try:
            num_str = input(self._color("Enter line number to remove (or 'c' to cancel): ", 'prompt')).strip()
            if num_str.lower() == 'c':
                return

            num = int(num_str)
            if num < 1 or num > len(all_changes):
                print(self._color(f"Invalid line number. Must be 1-{len(all_changes)}", 'warning'))
                return

            change, category = all_changes[num - 1]
            desc = change.get('description', '')

            confirm = input(self._color(f"Remove '{desc}'? [y/n]: ", 'prompt')).strip().lower()

            if confirm == 'y':
                grouped[category].remove(change)
                print(self._color("Removed!", 'highlight'))

        except ValueError:
            print(self._color("Invalid input.", 'warning'))
        except (EOFError, KeyboardInterrupt):
            print()

    def _get_flat_list(self, grouped: Dict[str, List[Dict[str, Any]]]) -> List[Tuple[Dict[str, Any], str]]:
        """Get a flat list of (change, category) tuples."""
        result = []
        sorted_cats = self.config.get_sorted_categories()

        for category in sorted_cats:
            changes = grouped.get(category, [])
            for change in changes:
                result.append((change, category))

        return result

    def _show_help(self) -> None:
        """Show detailed help."""
        print()
        print(self._color("=== Preview Mode Help ===", 'header'))
        print()
        print("Basic Actions:")
        print("  c, confirm   - Accept changes and proceed to save")
        print("  q, quit      - Cancel and exit without saving")
        print("  v, view      - Display all changes again")
        print()
        print("Editing:")
        print("  e, edit      - Edit a specific change by line number")
        print("  r, remove    - Remove a specific change by line number")
        print()
        print("Tips:")
        print("  - Line numbers are shown in brackets [1], [2], etc.")
        print("  - Use these numbers with edit/remove commands")
        print("  - Changes are grouped by category (New Features, Bug Fixes, etc.)")
        print("  - Edits are temporary until you confirm")
        print()

    def quick_preview(self, grouped: Dict[str, List[Dict[str, Any]]]) -> str:
        """
        Generate a quick text preview without interaction.

        Useful for logging or when interactivity is not available.

        Args:
            grouped: Changes grouped by category

        Returns:
            Formatted text preview
        """
        lines = []
        lines.append("=" * 50)
        lines.append("CHANGELOG PREVIEW")
        lines.append("=" * 50)
        lines.append("")

        sorted_cats = self.config.get_sorted_categories()

        for category in sorted_cats:
            changes = grouped.get(category, [])
            if not changes:
                continue

            cat_config = self.config.get_category_config(category)
            heading = cat_config.get('heading', category.title())
            lines.append(f"## {heading}")
            lines.append("")

            for change in changes:
                desc = change.get('description', '')
                lines.append(f"  - {desc}")

            lines.append("")

        return '\n'.join(lines)

    def show_summary(self, result: Dict[str, Any]) -> None:
        """
        Show a quick summary without full preview.

        Args:
            result: Result dictionary from ChangelogGenerator.generate()
        """
        stats = result.get('stats', {})

        print(self._color("\nChangelog Summary:", 'header'))
        print(f"  Total commits: {stats.get('total_commits', 0)}")
        print(f"  Changes found: {stats.get('total_changes', 0)}")

        by_category = stats.get('by_category', {})
        if by_category:
            print("\n  Categories:")
            for cat, count in sorted(by_category.items()):
                cat_config = self.config.get_category_config(cat)
                heading = cat_config.get('heading', cat.title())
                print(f"    {heading}: {count}")
        print()
