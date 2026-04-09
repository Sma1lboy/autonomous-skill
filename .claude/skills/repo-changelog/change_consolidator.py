"""
Change consolidator module.
Merges related changes, eliminates flip-flop changes (net-zero),
and produces a clean list of actual changes for the changelog.

Now uses config.yaml for customizable thresholds and settings.
Includes semantic analysis for cross-reference detection.
"""

import re
from typing import Dict, List, Any, Optional, Set, Tuple
from collections import defaultdict
from difflib import SequenceMatcher

# Import config loader
try:
    from .config_loader import get_config
except ImportError:
    from config_loader import get_config

# Import semantic analyzer for cross-reference detection
try:
    from .semantic_analyzer import SemanticAnalyzer
except ImportError:
    try:
        from semantic_analyzer import SemanticAnalyzer
    except ImportError:
        SemanticAnalyzer = None  # Graceful fallback


class ChangeConsolidator:
    """
    Consolidates changes across multiple commits into a clean changelog.

    Key responsibilities:
    - Detect and eliminate flip-flop changes (changed and then changed back)
    - Merge related changes into single descriptions
    - Deduplicate similar changes
    - Cross-reference detection to group related file changes
    - Focus on end result, not intermediate steps

    All settings configurable via config.yaml.
    """

    def __init__(self, config_path: Optional[str] = None):
        """
        Initialize the consolidator.

        Args:
            config_path: Optional path to custom config file
        """
        self.config = get_config(config_path)
        self.config_path = config_path
        self.tracked_items: Dict[str, List[Dict[str, Any]]] = defaultdict(list)

        # Load settings from config
        self.similarity_threshold = self.config.get(
            'consolidation', 'similarity_threshold', default=0.7
        )
        self.remove_flipflops = self.config.get(
            'consolidation', 'remove_flipflops', default=True
        )
        self.merge_similar = self.config.get(
            'consolidation', 'merge_similar', default=True
        )
        self.min_confidence = self.config.get(
            'consolidation', 'min_confidence', default='low'
        )

        # Semantic analysis settings
        self.use_semantic_grouping = self.config.get(
            'file_relationships', 'enabled', default=True
        )

        # Initialize semantic analyzer if available
        if SemanticAnalyzer and self.use_semantic_grouping:
            self.semantic_analyzer = SemanticAnalyzer(config_path)
        else:
            self.semantic_analyzer = None

    def consolidate(self, all_changes: List[Dict[str, Any]],
                    initial_state: Optional[Dict[str, Any]] = None,
                    final_state: Optional[Dict[str, Any]] = None) -> List[Dict[str, Any]]:
        """
        Consolidate all changes into a clean list.

        Args:
            all_changes: All detected changes from all commits
            initial_state: Optional initial state snapshot for comparison
            final_state: Optional final state snapshot for comparison

        Returns:
            Consolidated list of changes
        """
        if not all_changes:
            return []

        # Step 1: Remove exact duplicates
        unique_changes = self._remove_duplicates(all_changes)

        # Step 2: Semantic grouping - group related file changes (NEW)
        if self.semantic_analyzer:
            semantically_grouped = self.semantic_analyzer.group_related_changes(unique_changes)
        else:
            semantically_grouped = unique_changes

        # Step 3: Merge similar changes (if enabled in config)
        if self.merge_similar:
            merged_changes = self._merge_similar(semantically_grouped)
        else:
            merged_changes = semantically_grouped

        # Step 4: Detect and remove flip-flop changes (if enabled in config)
        if self.remove_flipflops:
            net_changes = self._remove_flipflops_logic(merged_changes, initial_state, final_state)
        else:
            net_changes = merged_changes

        # Step 5: Filter out low-confidence or irrelevant changes
        filtered_changes = self._filter_changes(net_changes)

        # Step 6: Sort by category and confidence
        sorted_changes = self._sort_changes(filtered_changes)

        return sorted_changes

    def _remove_duplicates(self, changes: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        """
        Remove exact duplicate changes.

        Args:
            changes: List of changes

        Returns:
            Deduplicated list
        """
        seen_descriptions = set()
        unique = []

        for change in changes:
            # Normalize description for comparison
            desc_key = self._normalize_description(change.get('description', ''))

            if desc_key and desc_key not in seen_descriptions:
                seen_descriptions.add(desc_key)
                unique.append(change)

        return unique

    def _normalize_description(self, description: str) -> str:
        """Normalize description for comparison."""
        if not description:
            return ''

        # Lowercase
        normalized = description.lower()

        # Remove punctuation
        normalized = re.sub(r'[^\w\s]', '', normalized)

        # Remove extra whitespace
        normalized = ' '.join(normalized.split())

        return normalized

    def _merge_similar(self, changes: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        """
        Merge similar changes into consolidated descriptions.

        Args:
            changes: List of changes

        Returns:
            Merged list
        """
        if len(changes) <= 1:
            return changes

        merged = []
        used_indices = set()

        for i, change1 in enumerate(changes):
            if i in used_indices:
                continue

            # Find similar changes
            similar_group = [change1]

            for j, change2 in enumerate(changes[i + 1:], start=i + 1):
                if j in used_indices:
                    continue

                # Check if same category and similar description
                if change1.get('category') == change2.get('category'):
                    similarity = self._calculate_similarity(
                        change1.get('description', ''),
                        change2.get('description', '')
                    )

                    if similarity >= self.similarity_threshold:
                        similar_group.append(change2)
                        used_indices.add(j)

            # Merge the group
            if len(similar_group) > 1:
                merged_change = self._merge_group(similar_group)
                merged.append(merged_change)
            else:
                merged.append(change1)

            used_indices.add(i)

        return merged

    def _calculate_similarity(self, text1: str, text2: str) -> float:
        """Calculate similarity between two texts."""
        if not text1 or not text2:
            return 0.0

        return SequenceMatcher(None, text1.lower(), text2.lower()).ratio()

    def _merge_group(self, group: List[Dict[str, Any]]) -> Dict[str, Any]:
        """
        Merge a group of similar changes into one.

        Args:
            group: List of similar changes

        Returns:
            Single merged change
        """
        # Use the highest confidence one as the base
        base = max(group, key=lambda x: self._confidence_score(x.get('confidence', 'low')))

        # If there are multiple items, indicate it
        if len(group) > 2:
            base = base.copy()
            base['description'] = f"{base['description']} (multiple improvements)"

        return base

    def _confidence_score(self, confidence: str) -> int:
        """Convert confidence to numeric score."""
        scores = {'high': 3, 'medium': 2, 'low': 1}
        return scores.get(confidence, 0)

    def _remove_flipflops_logic(self, changes: List[Dict[str, Any]],
                          initial_state: Optional[Dict[str, Any]],
                          final_state: Optional[Dict[str, Any]]) -> List[Dict[str, Any]]:
        """
        Remove flip-flop changes where the net result is no change.

        A flip-flop is when something changes and then changes back,
        resulting in no actual difference in the final product.

        Args:
            changes: List of changes
            initial_state: Initial state snapshot
            final_state: Final state snapshot

        Returns:
            Changes with flip-flops removed
        """
        # Track items that were both added and removed
        added_items = set()
        removed_items = set()

        for change in changes:
            desc = self._normalize_description(change.get('description', ''))

            # Detect add/remove patterns
            if self._is_addition(change):
                added_items.add(desc)
            elif self._is_removal(change):
                removed_items.add(desc)

        # Items that were both added and removed are flip-flops
        flipflops = added_items.intersection(removed_items)

        # Filter out flip-flops
        filtered = []
        for change in changes:
            desc = self._normalize_description(change.get('description', ''))

            # Skip if this is a flip-flop
            if desc in flipflops:
                continue

            # Check for "changed X to Y" and "changed Y to X" patterns
            if not self._is_reverse_change(change, changes):
                filtered.append(change)

        return filtered

    def _is_addition(self, change: Dict[str, Any]) -> bool:
        """Check if change represents an addition."""
        desc = change.get('description', '').lower()
        category = change.get('category', '')

        add_keywords = ['added', 'new', 'created', 'introduced', 'implemented']
        return category == 'feature' or any(kw in desc for kw in add_keywords)

    def _is_removal(self, change: Dict[str, Any]) -> bool:
        """Check if change represents a removal."""
        desc = change.get('description', '').lower()

        remove_keywords = ['removed', 'deleted', 'deprecated', 'dropped', 'eliminated']
        return any(kw in desc for kw in remove_keywords)

    def _is_reverse_change(self, change: Dict[str, Any],
                           all_changes: List[Dict[str, Any]]) -> bool:
        """
        Check if there's a reverse change that cancels this one out.

        For example:
        - "Changed timeout to 30" and "Changed timeout to 10" (if 10 was original)
        - "Enabled dark mode" and "Disabled dark mode"
        """
        desc = change.get('description', '').lower()

        # Check for toggle reversals
        if 'enabled' in desc:
            reverse = desc.replace('enabled', 'disabled')
            for other in all_changes:
                if self._normalize_description(other.get('description', '')) == self._normalize_description(reverse):
                    return True

        if 'disabled' in desc:
            reverse = desc.replace('disabled', 'enabled')
            for other in all_changes:
                if self._normalize_description(other.get('description', '')) == self._normalize_description(reverse):
                    return True

        return False

    def _filter_changes(self, changes: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        """
        Filter out low-quality or irrelevant changes.

        Args:
            changes: List of changes

        Returns:
            Filtered list
        """
        filtered = []

        for change in changes:
            desc = change.get('description', '')

            # Skip empty descriptions
            if not desc or len(desc) < 5:
                continue

            # Skip changes that are too technical
            if self._is_too_technical(desc):
                continue

            # Skip changes with very low confidence from file analysis
            if (change.get('confidence') == 'low' and
                change.get('source') == 'file_analysis'):
                continue

            filtered.append(change)

        return filtered

    def _is_too_technical(self, description: str) -> bool:
        """Check if description is too technical for end users."""
        technical_patterns = [
            r'\b(function|method|class|module|variable|const|var|let)\b',
            r'\b(import|export|require|include)\b',
            r'\b(api|endpoint|callback|handler|middleware)\b',
            r'\b(refactor|lint|format|syntax)\b',
            r'\(\)\s*$',  # Ends with function call
            r'->\s*\w+',  # Arrow notation
            r'\w+\.\w+\.\w+',  # Deep property access
            r'[{}\[\]<>]',  # Code brackets
        ]

        desc_lower = description.lower()
        for pattern in technical_patterns:
            if re.search(pattern, desc_lower):
                return True

        return False

    def _sort_changes(self, changes: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        """
        Sort changes by category and confidence.

        Args:
            changes: List of changes

        Returns:
            Sorted list
        """
        category_order = {
            'breaking': 0,
            'feature': 1,
            'enhancement': 2,
            'bugfix': 3,
            'change': 4,
            'other': 5
        }

        confidence_order = {
            'high': 0,
            'medium': 1,
            'low': 2
        }

        return sorted(changes, key=lambda x: (
            category_order.get(x.get('category', 'other'), 99),
            confidence_order.get(x.get('confidence', 'low'), 99)
        ))

    def group_by_category(self, changes: List[Dict[str, Any]],
                          audience: str = 'end-users') -> Dict[str, List[Dict[str, Any]]]:
        """
        Group changes by category for formatting.

        Args:
            changes: Consolidated list of changes
            audience: Target audience for category ordering

        Returns:
            Dictionary mapping category to list of changes
        """
        grouped = defaultdict(list)

        for change in changes:
            category = change.get('category', 'other')
            grouped[category].append(change)

        return dict(grouped)
