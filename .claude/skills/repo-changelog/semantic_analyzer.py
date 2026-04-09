"""
Semantic analyzer module for cross-reference detection.
Groups related file changes and detects feature-level changes.

Analyzes file paths and change patterns to consolidate fragmented
changelog entries into meaningful, user-friendly descriptions.
"""

import re
import fnmatch
from typing import Dict, List, Any, Optional, Set, Tuple
from collections import defaultdict
from pathlib import Path

# Import config loader
try:
    from .config_loader import get_config
except ImportError:
    from config_loader import get_config


class SemanticAnalyzer:
    """
    Analyzes file changes to detect semantic relationships.

    Responsibilities:
    - Group related file changes by functional area
    - Detect feature-level changes spanning multiple areas
    - Suggest consolidated descriptions
    - Identify primary change area
    """

    # Default file area patterns (used if not in config)
    DEFAULT_AREAS = {
        'authentication': {
            'patterns': [
                '**/auth/**', '**/login/**', '**/session/**',
                '**/*auth*', '**/*login*', '**/*session*',
                '**/signin/**', '**/signup/**'
            ],
            'consolidation_phrase': 'authentication',
            'priority': 1
        },
        'user_interface': {
            'patterns': [
                '**/*.tsx', '**/*.jsx', '**/*.vue', '**/*.svelte',
                '**/*.css', '**/*.scss', '**/*.less',
                '**/components/**', '**/pages/**', '**/views/**',
                '**/ui/**', '**/frontend/**'
            ],
            'consolidation_phrase': 'user interface',
            'priority': 2
        },
        'api_endpoints': {
            'patterns': [
                '**/routes/**', '**/api/**', '**/controllers/**',
                '**/handlers/**', '**/endpoints/**',
                '**/*route*', '**/*controller*', '**/*handler*'
            ],
            'consolidation_phrase': 'API',
            'priority': 1
        },
        'database': {
            'patterns': [
                '**/models/**', '**/migrations/**', '**/schema/**',
                '**/*repository*', '**/*model*', '**/*entity*',
                '**/*.sql', '**/db/**'
            ],
            'consolidation_phrase': 'data handling',
            'priority': 1
        },
        'configuration': {
            'patterns': [
                '**/*.yaml', '**/*.yml', '**/*.json', '**/*.toml',
                '**/*.ini', '**/.env*', '**/config/**',
                '**/*config*', '**/*settings*'
            ],
            'consolidation_phrase': 'configuration',
            'priority': 3
        },
        'testing': {
            'patterns': [
                '**/test/**', '**/tests/**', '**/spec/**',
                '**/*test*', '**/*spec*', '**/__tests__/**'
            ],
            'consolidation_phrase': 'testing',
            'priority': 4
        },
        'documentation': {
            'patterns': [
                '**/*.md', '**/*.rst', '**/*.txt',
                '**/docs/**', '**/documentation/**',
                '**/README*', '**/CHANGELOG*'
            ],
            'consolidation_phrase': 'documentation',
            'priority': 5
        }
    }

    # Default feature indicators
    DEFAULT_FEATURE_INDICATORS = [
        {'min_areas': 3, 'category': 'feature', 'template': 'Added new {primary} feature'},
        {'min_areas': 2, 'category': 'enhancement', 'template': 'Improved {primary}'}
    ]

    def __init__(self, config_path: Optional[str] = None):
        """
        Initialize the semantic analyzer.

        Args:
            config_path: Optional path to custom config file
        """
        self.config = get_config(config_path)

        # Load areas from config or use defaults
        config_areas = self.config.get('file_relationships', 'areas', default=None)
        if config_areas:
            self.areas = config_areas
        else:
            self.areas = self.DEFAULT_AREAS

        # Load feature indicators from config or use defaults
        config_indicators = self.config.get(
            'file_relationships', 'feature_indicators', default=None
        )
        if config_indicators:
            self.feature_indicators = config_indicators
        else:
            self.feature_indicators = self.DEFAULT_FEATURE_INDICATORS

        # Enable/disable semantic grouping
        self.enabled = self.config.get(
            'file_relationships', 'enabled', default=True
        )

        # Minimum files to trigger grouping
        self.min_files_for_grouping = self.config.get(
            'file_relationships', 'min_files_for_grouping', default=2
        )

    def analyze_commit(self, files_changed: List[Dict[str, str]]) -> Dict[str, Any]:
        """
        Analyze files changed in a commit to detect relationships.

        Args:
            files_changed: List of {'path': str, 'status': str} dicts

        Returns:
            Analysis result with areas, primary area, and suggestions
        """
        if not self.enabled or not files_changed:
            return {
                'areas': [],
                'primary_area': None,
                'is_feature': False,
                'suggested_description': None,
                'confidence': 0.0
            }

        # Detect areas for each file
        file_areas = {}
        area_counts = defaultdict(int)

        for file_info in files_changed:
            path = file_info.get('path', '')
            detected = self._detect_areas(path)
            file_areas[path] = detected
            for area in detected:
                area_counts[area] += 1

        # Determine unique areas
        unique_areas = list(area_counts.keys())

        # Determine primary area (highest count, then highest priority)
        primary_area = self._get_primary_area(area_counts)

        # Check if this looks like a feature (multiple areas touched)
        is_feature = len(unique_areas) >= 2
        suggested_description = None
        confidence = 0.0

        # Generate suggestion based on feature indicators
        if is_feature:
            for indicator in self.feature_indicators:
                min_areas = indicator.get('min_areas', 2)
                if len(unique_areas) >= min_areas:
                    template = indicator.get('template', 'Updated {primary}')
                    phrase = self._get_consolidation_phrase(primary_area)
                    suggested_description = template.format(primary=phrase)
                    confidence = min(0.9, 0.5 + (len(unique_areas) * 0.15))
                    break

        return {
            'areas': unique_areas,
            'primary_area': primary_area,
            'is_feature': is_feature,
            'suggested_description': suggested_description,
            'confidence': confidence,
            'file_areas': file_areas,
            'area_counts': dict(area_counts)
        }

    def _detect_areas(self, file_path: str) -> List[str]:
        """Detect which areas a file belongs to."""
        detected = []

        for area_name, area_config in self.areas.items():
            patterns = area_config.get('patterns', [])
            for pattern in patterns:
                if self._matches_pattern(file_path, pattern):
                    detected.append(area_name)
                    break  # File matched this area, move to next area

        return detected

    def _matches_pattern(self, file_path: str, pattern: str) -> bool:
        """Check if file path matches a glob pattern."""
        # Normalize path separators
        normalized_path = file_path.replace('\\', '/')
        normalized_pattern = pattern.replace('\\', '/')

        # Use fnmatch for glob matching
        return fnmatch.fnmatch(normalized_path, normalized_pattern)

    def _get_primary_area(self, area_counts: Dict[str, int]) -> Optional[str]:
        """Get the primary area based on count and priority."""
        if not area_counts:
            return None

        # Sort by count (descending), then by priority (ascending)
        def sort_key(area):
            count = area_counts[area]
            priority = self.areas.get(area, {}).get('priority', 99)
            return (-count, priority)

        sorted_areas = sorted(area_counts.keys(), key=sort_key)
        return sorted_areas[0] if sorted_areas else None

    def _get_consolidation_phrase(self, area: Optional[str]) -> str:
        """Get the consolidation phrase for an area."""
        if not area:
            return 'system'
        return self.areas.get(area, {}).get('consolidation_phrase', area)

    def group_related_changes(self, changes: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        """
        Group multiple change entries that are semantically related.

        Args:
            changes: List of change dictionaries with 'description', 'files', etc.

        Returns:
            Consolidated list with related changes merged
        """
        if not self.enabled or len(changes) < self.min_files_for_grouping:
            return changes

        # Group changes by their primary area
        area_groups: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
        ungrouped = []

        for change in changes:
            # Get files from change (may be in different keys)
            files = change.get('files_changed', change.get('files', []))
            if not files:
                # If no files, try to infer from raw field
                raw = change.get('raw', '')
                if raw:
                    files = [{'path': raw, 'status': 'modified'}]

            if files:
                # Analyze the files
                analysis = self.analyze_commit(files)
                primary_area = analysis.get('primary_area')

                if primary_area:
                    area_groups[primary_area].append({
                        **change,
                        '_analysis': analysis
                    })
                else:
                    ungrouped.append(change)
            else:
                ungrouped.append(change)

        # Consolidate groups with 2+ changes
        consolidated = []

        for area, group in area_groups.items():
            if len(group) >= 2:
                # Merge this group
                merged = self._merge_area_group(area, group)
                consolidated.append(merged)
            else:
                # Single item, keep as-is but remove analysis
                for item in group:
                    item.pop('_analysis', None)
                    consolidated.append(item)

        # Add ungrouped changes
        consolidated.extend(ungrouped)

        return consolidated

    def _merge_area_group(self, area: str, group: List[Dict[str, Any]]) -> Dict[str, Any]:
        """Merge a group of changes in the same area."""
        phrase = self._get_consolidation_phrase(area)

        # Determine the best category (prioritize feature > enhancement > others)
        categories = [c.get('category', 'other') for c in group]
        category_priority = {'feature': 0, 'enhancement': 1, 'bugfix': 2, 'change': 3, 'other': 4}
        best_category = min(categories, key=lambda c: category_priority.get(c, 99))

        # Get highest confidence
        confidences = ['high', 'medium', 'low']
        conf_priority = {c: i for i, c in enumerate(confidences)}
        group_confidences = [g.get('confidence', 'low') for g in group]
        best_confidence = min(group_confidences, key=lambda c: conf_priority.get(c, 99))

        # Generate merged description
        action_words = self._extract_action_words(group)
        if action_words:
            description = f"{action_words[0].capitalize()} {phrase}"
            if len(action_words) > 1:
                description += f" ({', '.join(action_words[1:])})"
        else:
            description = f"Updated {phrase}"

        # Add context about number of changes
        if len(group) > 2:
            description += f" (multiple improvements)"

        return {
            'description': description,
            'category': best_category,
            'confidence': best_confidence,
            'source': 'semantic_consolidation',
            'source_count': len(group),
            'area': area,
            '_original_changes': group  # Keep for audit
        }

    def _extract_action_words(self, changes: List[Dict[str, Any]]) -> List[str]:
        """Extract action words from change descriptions."""
        action_patterns = [
            (r'\b(add(?:ed)?)\b', 'Added'),
            (r'\b(creat(?:ed?|ing))\b', 'Added'),
            (r'\b(implement(?:ed)?)\b', 'Added'),
            (r'\b(fix(?:ed)?)\b', 'Fixed'),
            (r'\b(resolv(?:ed?|ing))\b', 'Fixed'),
            (r'\b(improv(?:ed?|ing))\b', 'Improved'),
            (r'\b(enhanc(?:ed?|ing))\b', 'Improved'),
            (r'\b(updat(?:ed?|ing))\b', 'Updated'),
            (r'\b(chang(?:ed?|ing))\b', 'Changed'),
            (r'\b(remov(?:ed?|ing))\b', 'Removed'),
            (r'\b(delet(?:ed?|ing))\b', 'Removed'),
        ]

        found_actions = []
        for change in changes:
            desc = change.get('description', '').lower()
            for pattern, action in action_patterns:
                if re.search(pattern, desc) and action not in found_actions:
                    found_actions.append(action)
                    break

        return found_actions

    def detect_feature_boundary(self, commits: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        """
        Detect when multiple commits form a single feature.

        Looks for patterns like:
        - "Add X" followed by "Fix X" followed by "Improve X"
        - Multiple commits touching same file areas

        Args:
            commits: List of commit dictionaries

        Returns:
            List of detected feature groups
        """
        if not commits or len(commits) < 2:
            return []

        # Track commits by their touched areas
        commit_areas: List[Tuple[Dict, Set[str]]] = []

        for commit in commits:
            files = commit.get('files_changed', [])
            analysis = self.analyze_commit(files)
            areas = set(analysis.get('areas', []))
            commit_areas.append((commit, areas))

        # Find sequences of commits with overlapping areas
        features = []
        current_feature = []
        current_areas = set()

        for commit, areas in commit_areas:
            if not current_areas:
                # Start new feature
                current_feature = [commit]
                current_areas = areas
            elif areas & current_areas:  # Overlapping areas
                # Continue feature
                current_feature.append(commit)
                current_areas |= areas
            else:
                # Non-overlapping, save current and start new
                if len(current_feature) >= 2:
                    features.append({
                        'commits': current_feature,
                        'areas': list(current_areas)
                    })
                current_feature = [commit]
                current_areas = areas

        # Don't forget last feature
        if len(current_feature) >= 2:
            features.append({
                'commits': current_feature,
                'areas': list(current_areas)
            })

        return features

    def get_area_summary(self, files_changed: List[Dict[str, str]]) -> str:
        """
        Get a human-readable summary of areas touched.

        Args:
            files_changed: List of file change dicts

        Returns:
            Summary string like "authentication, user interface"
        """
        analysis = self.analyze_commit(files_changed)
        areas = analysis.get('areas', [])

        if not areas:
            return 'general'

        phrases = [self._get_consolidation_phrase(a) for a in areas]
        return ', '.join(phrases)
