"""
Configuration loader module.
Loads and validates config.yaml, merging with defaults.
"""

import os
import yaml
from typing import Dict, Any, Optional
from pathlib import Path


class ConfigLoader:
    """
    Loads and manages configuration for repo-changelog skill.

    Supports:
    - Default config from skill directory
    - User override config
    - Environment variable overrides
    - Validation of required fields
    """

    # Default config location (relative to this file)
    DEFAULT_CONFIG_NAME = "config.yaml"

    def __init__(self, config_path: Optional[str] = None):
        """
        Initialize config loader.

        Args:
            config_path: Optional path to custom config file
        """
        self.config: Dict[str, Any] = {}
        self.config_path = config_path
        self._load_config()

    def _get_default_config_path(self) -> Path:
        """Get path to default config.yaml in skill directory."""
        return Path(__file__).parent / self.DEFAULT_CONFIG_NAME

    def _load_config(self) -> None:
        """Load configuration from file(s)."""
        # Start with defaults
        self.config = self._get_hardcoded_defaults()

        # Load default config file
        default_path = self._get_default_config_path()
        if default_path.exists():
            default_config = self._load_yaml(default_path)
            self.config = self._deep_merge(self.config, default_config)

        # Load custom config if provided
        if self.config_path:
            custom_path = Path(self.config_path)
            if custom_path.exists():
                custom_config = self._load_yaml(custom_path)
                self.config = self._deep_merge(self.config, custom_config)
            else:
                raise FileNotFoundError(f"Config file not found: {self.config_path}")

        # Apply environment variable overrides
        self._apply_env_overrides()

    def _load_yaml(self, path: Path) -> Dict[str, Any]:
        """Load YAML file."""
        try:
            with open(path, 'r', encoding='utf-8') as f:
                return yaml.safe_load(f) or {}
        except yaml.YAMLError as e:
            raise ValueError(f"Invalid YAML in {path}: {e}")
        except Exception as e:
            raise IOError(f"Error reading {path}: {e}")

    def _deep_merge(self, base: Dict, override: Dict) -> Dict:
        """
        Deep merge two dictionaries.
        Override values take precedence.
        """
        result = base.copy()

        for key, value in override.items():
            if key in result and isinstance(result[key], dict) and isinstance(value, dict):
                result[key] = self._deep_merge(result[key], value)
            else:
                result[key] = value

        return result

    def _get_hardcoded_defaults(self) -> Dict[str, Any]:
        """
        Hardcoded defaults as fallback.
        These are used if config.yaml is missing.
        """
        return {
            'output': {
                'directory': 'RELEASE_NOTES',
                'filename_format': 'RELEASE_NOTES_{version}_{datetime}.md',
                'filename_format_no_version': 'RELEASE_NOTES_{datetime}.md',
                'datetime_format': '%Y%m%d_%H%M%S',
                'include_date_header': True,
                'header_date_format': '%Y-%m-%d'
            },
            'categories': {
                'breaking': {'heading': 'Breaking Changes', 'order': 0, 'keywords': ['breaking', 'BREAKING CHANGE']},
                'feature': {'heading': 'New Features', 'order': 1, 'keywords': ['feat', 'add', 'new']},
                'enhancement': {'heading': 'Enhancements', 'order': 2, 'keywords': ['enhance', 'improve', 'update']},
                'bugfix': {'heading': 'Bug Fixes', 'order': 3, 'keywords': ['fix', 'bug', 'resolve']},
                'change': {'heading': 'Changes', 'order': 4, 'keywords': ['change', 'modify', 'refactor']},
                'other': {'heading': 'Other Updates', 'order': 5, 'keywords': []}
            },
            'filters': {
                'ignore_commit_patterns': ['^Merge ', '^WIP', '^fixup!'],
                'ignore_file_patterns': ['*.lock', '*.min.js', '__pycache__/*'],
                'exclude_categories': []
            },
            'ai_interpretation': {
                'enabled': True,
                'max_diff_size': 5000,
                'max_files_per_commit': 10,
                'fallback_to_patterns': True
            },
            'consolidation': {
                'similarity_threshold': 0.7,
                'remove_flipflops': True,
                'merge_similar': True,
                'max_per_category': 0,
                'min_confidence': 'low'
            },
            'breaking_changes': {
                'commit_keywords': ['BREAKING', 'BREAKING CHANGE'],
                'conventional_breaking_indicator': '!',
                'detect_from_diff': True
            },
            'slack': {
                'max_items_per_category': 5,
                'show_overflow_count': True,
                'use_slack_markdown': True
            },
            'git': {
                'default_commit_count': 50,
                'max_commits': 500,
                'command_timeout': 60,
                'include_merge_commits': False
            }
        }

    def _apply_env_overrides(self) -> None:
        """Apply environment variable overrides."""
        env_mappings = {
            'CHANGELOG_OUTPUT_DIR': ('output', 'directory'),
            'CHANGELOG_AI_ENABLED': ('ai_interpretation', 'enabled'),
            'CHANGELOG_MAX_COMMITS': ('git', 'max_commits'),
        }

        for env_var, config_path in env_mappings.items():
            value = os.environ.get(env_var)
            if value is not None:
                self._set_nested(self.config, config_path, self._parse_env_value(value))

    def _set_nested(self, d: Dict, path: tuple, value: Any) -> None:
        """Set a nested dictionary value by path."""
        for key in path[:-1]:
            d = d.setdefault(key, {})
        d[path[-1]] = value

    def _parse_env_value(self, value: str) -> Any:
        """Parse environment variable value to appropriate type."""
        # Boolean
        if value.lower() in ('true', 'yes', '1'):
            return True
        if value.lower() in ('false', 'no', '0'):
            return False

        # Integer
        try:
            return int(value)
        except ValueError:
            pass

        # Float
        try:
            return float(value)
        except ValueError:
            pass

        # String
        return value

    def get(self, *keys: str, default: Any = None) -> Any:
        """
        Get a config value by key path.

        Args:
            *keys: Key path (e.g., 'output', 'directory')
            default: Default value if not found

        Returns:
            Config value or default

        Example:
            config.get('output', 'directory')  # Returns 'RELEASE_NOTES'
        """
        value = self.config
        for key in keys:
            if isinstance(value, dict) and key in value:
                value = value[key]
            else:
                return default
        return value

    def get_category_config(self, category: str) -> Dict[str, Any]:
        """Get configuration for a specific category."""
        categories = self.get('categories', default={})
        return categories.get(category, {
            'heading': category.title(),
            'order': 99,
            'keywords': []
        })

    def get_all_keywords(self) -> Dict[str, list]:
        """Get all keywords mapped to their categories."""
        result = {}
        categories = self.get('categories', default={})

        for cat_name, cat_config in categories.items():
            for keyword in cat_config.get('keywords', []):
                result[keyword.lower()] = cat_name

        return result

    def should_ignore_commit(self, message: str) -> bool:
        """Check if a commit should be ignored based on patterns."""
        import re
        patterns = self.get('filters', 'ignore_commit_patterns', default=[])

        for pattern in patterns:
            if re.search(pattern, message, re.IGNORECASE):
                return True
        return False

    def should_ignore_file(self, filepath: str) -> bool:
        """Check if a file should be ignored in diff analysis."""
        import fnmatch
        patterns = self.get('filters', 'ignore_file_patterns', default=[])

        for pattern in patterns:
            if fnmatch.fnmatch(filepath, pattern):
                return True
        return False

    def get_sorted_categories(self) -> list:
        """Get category names sorted by their order."""
        categories = self.get('categories', default={})
        return sorted(
            categories.keys(),
            key=lambda c: categories[c].get('order', 99)
        )

    def validate(self) -> list:
        """
        Validate configuration.

        Returns:
            List of validation error messages (empty if valid)
        """
        errors = []

        # Check required sections exist
        required_sections = ['output', 'categories']
        for section in required_sections:
            if section not in self.config:
                errors.append(f"Missing required section: {section}")

        # Validate output settings
        output = self.get('output', default={})
        if not output.get('directory'):
            errors.append("output.directory is required")
        if not output.get('filename_format'):
            errors.append("output.filename_format is required")

        # Validate categories have required fields
        categories = self.get('categories', default={})
        for cat_name, cat_config in categories.items():
            if 'heading' not in cat_config:
                errors.append(f"Category '{cat_name}' missing 'heading'")
            if 'order' not in cat_config:
                errors.append(f"Category '{cat_name}' missing 'order'")

        # Validate numeric ranges
        threshold = self.get('consolidation', 'similarity_threshold', default=0.7)
        if not (0 <= threshold <= 1):
            errors.append("consolidation.similarity_threshold must be between 0 and 1")

        max_commits = self.get('git', 'max_commits', default=500)
        if max_commits < 1:
            errors.append("git.max_commits must be positive")

        return errors

    def reload(self) -> None:
        """Reload configuration from files."""
        self._load_config()

    def to_dict(self) -> Dict[str, Any]:
        """Return full config as dictionary."""
        return self.config.copy()


# Global config instance (lazy loaded)
_config_instance: Optional[ConfigLoader] = None


def get_config(config_path: Optional[str] = None, reload: bool = False) -> ConfigLoader:
    """
    Get the global config instance.

    Args:
        config_path: Optional custom config path
        reload: Force reload of config

    Returns:
        ConfigLoader instance
    """
    global _config_instance

    if _config_instance is None or reload or config_path:
        _config_instance = ConfigLoader(config_path)

    return _config_instance
