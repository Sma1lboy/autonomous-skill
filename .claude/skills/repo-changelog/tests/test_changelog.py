"""
Test suite for repo-changelog skill.

Run with: python -m pytest tests/ -v
Or: python tests/test_changelog.py
"""

import unittest
import sys
import os
from pathlib import Path

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from config_loader import ConfigLoader, get_config
from diff_parser import DiffParser
from change_consolidator import ChangeConsolidator
from changelog_formatter import ChangelogFormatter
from breaking_change_detector import BreakingChangeDetector
from ai_interpreter import AIInterpreter, MockAIClient
from semantic_analyzer import SemanticAnalyzer


class TestConfigLoader(unittest.TestCase):
    """Test configuration loading and validation."""

    def test_default_config_loads(self):
        """Default config should load without errors."""
        config = ConfigLoader()
        self.assertIsNotNone(config.config)

    def test_get_nested_value(self):
        """Should retrieve nested config values."""
        config = ConfigLoader()
        output_dir = config.get('output', 'directory')
        self.assertEqual(output_dir, 'RELEASE_NOTES')

    def test_get_with_default(self):
        """Should return default for missing keys."""
        config = ConfigLoader()
        value = config.get('nonexistent', 'key', default='fallback')
        self.assertEqual(value, 'fallback')

    def test_get_category_config(self):
        """Should return category configuration."""
        config = ConfigLoader()
        feature_config = config.get_category_config('feature')
        self.assertIn('heading', feature_config)
        self.assertIn('order', feature_config)

    def test_get_all_keywords(self):
        """Should return keyword to category mapping."""
        config = ConfigLoader()
        keywords = config.get_all_keywords()
        self.assertIsInstance(keywords, dict)
        self.assertIn('fix', keywords)

    def test_validate_config(self):
        """Config validation should pass for default config."""
        config = ConfigLoader()
        errors = config.validate()
        self.assertEqual(errors, [])


class TestDiffParser(unittest.TestCase):
    """Test diff parsing and interpretation."""

    def setUp(self):
        self.parser = DiffParser()

    def test_parse_empty_diff(self):
        """Should handle empty diffs gracefully."""
        changes = self.parser.parse_diff('', [], '')
        self.assertIsInstance(changes, list)

    def test_interpret_commit_message(self):
        """Should interpret commit messages."""
        result = self.parser._interpret_commit_message('feat: Add new login button')
        self.assertIsNotNone(result)
        self.assertEqual(result['category'], 'feature')

    def test_categorize_from_message(self):
        """Should categorize from conventional commit prefix."""
        self.assertEqual(self.parser._categorize_from_message('feat: something'), 'feature')
        self.assertEqual(self.parser._categorize_from_message('fix: something'), 'bugfix')
        self.assertEqual(self.parser._categorize_from_message('docs: something'), 'other')

    def test_humanize_description(self):
        """Should humanize technical descriptions."""
        result = self.parser._humanize_description('implement api endpoint')
        self.assertIn('Added', result)

    def test_looks_like_code(self):
        """Should detect code-like text."""
        self.assertTrue(self.parser._looks_like_code('foo()'))
        self.assertTrue(self.parser._looks_like_code('{}'))
        self.assertFalse(self.parser._looks_like_code('Added new feature'))


class TestChangeConsolidator(unittest.TestCase):
    """Test change consolidation and deduplication."""

    def setUp(self):
        self.consolidator = ChangeConsolidator()

    def test_empty_input(self):
        """Should handle empty input."""
        result = self.consolidator.consolidate([])
        self.assertEqual(result, [])

    def test_remove_duplicates(self):
        """Should remove exact duplicates."""
        changes = [
            {'description': 'Added feature', 'category': 'feature'},
            {'description': 'Added feature', 'category': 'feature'},
        ]
        result = self.consolidator._remove_duplicates(changes)
        self.assertEqual(len(result), 1)

    def test_normalize_description(self):
        """Should normalize descriptions for comparison."""
        norm1 = self.consolidator._normalize_description('Added Feature!')
        norm2 = self.consolidator._normalize_description('added feature')
        self.assertEqual(norm1, norm2)

    def test_calculate_similarity(self):
        """Should calculate text similarity."""
        sim = self.consolidator._calculate_similarity(
            'Updated the login button',
            'Updated the login form'
        )
        self.assertGreater(sim, 0.5)

    def test_group_by_category(self):
        """Should group changes by category."""
        changes = [
            {'description': 'Feature 1', 'category': 'feature'},
            {'description': 'Fix 1', 'category': 'bugfix'},
            {'description': 'Feature 2', 'category': 'feature'},
        ]
        grouped = self.consolidator.group_by_category(changes)
        self.assertEqual(len(grouped['feature']), 2)
        self.assertEqual(len(grouped['bugfix']), 1)


class TestChangelogFormatter(unittest.TestCase):
    """Test changelog formatting and output."""

    def setUp(self):
        self.formatter = ChangelogFormatter()

    def test_format_empty_changelog(self):
        """Should handle empty changelog."""
        result = self.formatter.format_changelog({})
        self.assertIn('Release Notes', result)

    def test_format_changelog_with_version(self):
        """Should include version in header."""
        result = self.formatter.format_changelog({}, version='v1.0.0')
        self.assertIn('v1.0.0', result)

    def test_format_category_section(self):
        """Should format category section correctly."""
        changes = [{'description': 'Added login button', 'category': 'feature'}]
        result = self.formatter._format_category_section('feature', changes)
        self.assertIn('New Features', result)
        self.assertIn('Added login button', result)

    def test_clean_description(self):
        """Should clean descriptions properly."""
        result = self.formatter._clean_description('added feature.')
        self.assertEqual(result, 'Added feature')

    def test_remove_technical_artifacts(self):
        """Should remove file paths and git hashes."""
        result = self.formatter._remove_technical_artifacts(
            'Fixed bug in /src/app.py with commit abc1234567'
        )
        self.assertNotIn('/src/app.py', result)
        self.assertNotIn('abc1234567', result)

    def test_format_slack_message(self):
        """Should format for Slack correctly."""
        grouped = {'feature': [{'description': 'New login', 'category': 'feature'}]}
        result = self.formatter.format_slack_message(grouped, version='v1.0.0')
        self.assertIn('*Release v1.0.0', result)
        self.assertIn('•', result)  # Slack bullet point

    def test_contains_sensitive_info(self):
        """Should detect sensitive information."""
        self.assertTrue(self.formatter._contains_sensitive_info('password: secret123'))
        self.assertTrue(self.formatter._contains_sensitive_info('api_key: ABC123'))
        self.assertFalse(self.formatter._contains_sensitive_info('Added new feature'))


class TestBreakingChangeDetector(unittest.TestCase):
    """Test breaking change detection."""

    def setUp(self):
        self.detector = BreakingChangeDetector()

    def test_detect_from_subject(self):
        """Should detect breaking change from commit subject."""
        changes = self.detector.detect('feat!: Remove old API')
        self.assertTrue(len(changes) > 0)

    def test_detect_from_body(self):
        """Should detect BREAKING CHANGE in commit body."""
        changes = self.detector.detect(
            'refactor: Update auth system',
            body='BREAKING CHANGE: The old auth tokens are no longer valid'
        )
        self.assertTrue(len(changes) > 0)

    def test_detect_from_keywords(self):
        """Should detect breaking change keywords."""
        changes = self.detector.detect('migration required for database')
        self.assertTrue(len(changes) > 0)

    def test_humanize_breaking_change(self):
        """Should humanize breaking change descriptions."""
        result = self.detector._humanize_breaking_change('removed api endpoint')
        self.assertIn('system', result.lower())

    def test_no_false_positives(self):
        """Should not detect breaking changes in normal commits."""
        changes = self.detector.detect('feat: Add new button')
        self.assertEqual(len(changes), 0)


class TestAIInterpreter(unittest.TestCase):
    """Test AI interpretation (with mock client)."""

    def setUp(self):
        self.interpreter = AIInterpreter()
        self.interpreter.set_ai_client(MockAIClient())

    def test_interpret_with_mock(self):
        """Should interpret using mock AI client."""
        commit = {
            'hash': 'abc123',
            'subject': 'Add new button to login form',
            'diff': '+  <button>Login</button>'
        }
        result = self.interpreter.interpret_commit(commit)
        self.assertIsNotNone(result)
        self.assertIn('button', result['description'].lower())

    def test_fallback_interpretation(self):
        """Should fallback to pattern matching."""
        interpreter = AIInterpreter()  # No AI client
        commit = {
            'hash': 'abc123',
            'subject': 'feat: Add user authentication',
            'diff': ''
        }
        result = interpreter.interpret_commit(commit)
        self.assertIsNotNone(result)

    def test_categorize_description(self):
        """Should categorize descriptions correctly."""
        self.assertEqual(
            self.interpreter._categorize_description('Added new feature'),
            'feature'
        )
        self.assertEqual(
            self.interpreter._categorize_description('Fixed login issue'),
            'bugfix'
        )

    def test_prepare_diff_truncation(self):
        """Should truncate large diffs."""
        large_diff = 'x' * 10000
        result = self.interpreter._prepare_diff(large_diff)
        self.assertLess(len(result), 6000)
        self.assertIn('truncated', result.lower())


class TestSemanticAnalyzer(unittest.TestCase):
    """Test semantic analysis and cross-reference detection."""

    def setUp(self):
        self.analyzer = SemanticAnalyzer()

    def test_detect_auth_area(self):
        """Should detect authentication area from file paths."""
        files = [{'path': 'src/auth/login.py', 'status': 'modified'}]
        result = self.analyzer.analyze_commit(files)
        self.assertIn('authentication', result['areas'])

    def test_detect_ui_area(self):
        """Should detect user interface area from file paths."""
        files = [{'path': 'components/Button.tsx', 'status': 'added'}]
        result = self.analyzer.analyze_commit(files)
        self.assertIn('user_interface', result['areas'])

    def test_detect_multiple_areas(self):
        """Should detect multiple areas when files span areas."""
        files = [
            {'path': 'src/auth/login.tsx', 'status': 'modified'},
            {'path': 'src/models/user.py', 'status': 'modified'},
            {'path': 'src/routes/auth.py', 'status': 'added'}
        ]
        result = self.analyzer.analyze_commit(files)
        self.assertGreaterEqual(len(result['areas']), 2)
        self.assertTrue(result['is_feature'])

    def test_primary_area_detection(self):
        """Should identify primary area based on file count."""
        files = [
            {'path': 'src/auth/login.py', 'status': 'modified'},
            {'path': 'src/auth/logout.py', 'status': 'modified'},
            {'path': 'src/components/Header.tsx', 'status': 'modified'}
        ]
        result = self.analyzer.analyze_commit(files)
        self.assertEqual(result['primary_area'], 'authentication')

    def test_consolidation_phrase(self):
        """Should return appropriate consolidation phrase."""
        phrase = self.analyzer._get_consolidation_phrase('authentication')
        self.assertEqual(phrase, 'authentication')

        phrase = self.analyzer._get_consolidation_phrase('database')
        self.assertEqual(phrase, 'data handling')

    def test_group_related_changes(self):
        """Should group changes by area."""
        changes = [
            {'description': 'Updated login', 'files_changed': [
                {'path': 'src/auth/login.py', 'status': 'modified'}
            ]},
            {'description': 'Fixed session', 'files_changed': [
                {'path': 'src/auth/session.py', 'status': 'modified'}
            ]},
            {'description': 'Updated button', 'files_changed': [
                {'path': 'src/components/Button.tsx', 'status': 'modified'}
            ]}
        ]
        result = self.analyzer.group_related_changes(changes)
        # Auth changes should be grouped, button stays separate
        self.assertLessEqual(len(result), len(changes))

    def test_empty_files(self):
        """Should handle empty file list gracefully."""
        result = self.analyzer.analyze_commit([])
        self.assertEqual(result['areas'], [])
        self.assertIsNone(result['primary_area'])
        self.assertFalse(result['is_feature'])

    def test_unknown_file_type(self):
        """Should handle unknown file types gracefully."""
        files = [{'path': 'random/file.xyz', 'status': 'added'}]
        result = self.analyzer.analyze_commit(files)
        # Should not crash, may return empty areas
        self.assertIsInstance(result['areas'], list)

    def test_area_summary(self):
        """Should generate readable area summary."""
        files = [
            {'path': 'src/auth/login.py', 'status': 'modified'},
            {'path': 'src/api/routes.py', 'status': 'modified'}
        ]
        summary = self.analyzer.get_area_summary(files)
        self.assertIn('authentication', summary.lower())


class TestIntegration(unittest.TestCase):
    """Integration tests for the full pipeline."""

    def test_full_pipeline(self):
        """Test complete change detection and formatting pipeline."""
        # Simulate commit with diff
        commit_subject = 'feat: Add dark mode toggle'
        diff_content = '''
diff --git a/src/theme.js b/src/theme.js
+  darkMode: true,
+  <button>Toggle Dark Mode</button>
'''
        files_changed = [
            {'status': 'modified', 'path': 'src/theme.js'}
        ]

        # Parse diff
        parser = DiffParser()
        changes = parser.parse_diff(diff_content, files_changed, commit_subject)

        # Consolidate
        consolidator = ChangeConsolidator()
        consolidated = consolidator.consolidate(changes)

        # Should have at least one change
        self.assertTrue(len(consolidated) > 0)

        # Group and format
        grouped = consolidator.group_by_category(consolidated)
        formatter = ChangelogFormatter()
        output = formatter.format_changelog(grouped, version='v1.0.0')

        # Output should be valid markdown
        self.assertIn('#', output)
        self.assertIn('-', output)


def run_tests():
    """Run all tests."""
    unittest.main(verbosity=2)


if __name__ == '__main__':
    run_tests()
