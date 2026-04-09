"""
Diff parser and interpreter.
Reads actual code diffs and translates them into plain English descriptions
that end-users can understand. No technical jargon, functions, or variables.

Now uses config.yaml for customizable patterns and keywords.
"""

import re
from typing import Dict, List, Any, Optional, Tuple
from pathlib import Path

# Import config loader
try:
    from .config_loader import get_config
except ImportError:
    from config_loader import get_config


class DiffParser:
    """
    Parses git diffs and interprets them into user-friendly descriptions.
    Focuses on the end result, not technical implementation details.
    """

    # Files to ignore (lock files, generated files, test files)
    IGNORE_FILES = [
        # Lock files
        'package-lock.json',
        'yarn.lock',
        'pnpm-lock.yaml',
        'Pipfile.lock',
        'poetry.lock',
        'Gemfile.lock',
        'composer.lock',
        'Cargo.lock',
        'go.sum',
        'requirements.txt',  # Often contains hashes
        'requirements-*.txt',
        '*.lock',
        '.terraform.lock.hcl',
        # Test files (don't extract "should..." patterns from tests)
        'test_*.py',
        '*_test.py',
        '*.test.js',
        '*.test.ts',
        '*.spec.js',
        '*.spec.ts',
        '**/test/**',
        '**/tests/**',
        '**/spec/**',
        '**/__tests__/**',
        # CI/CD files
        '.github/workflows/*.yml',
        '.github/workflows/*.yaml',
        '.gitlab-ci.yml',
        'Jenkinsfile',
        # Generated/vendor files
        '**/node_modules/**',
        '**/vendor/**',
        '**/dist/**',
        '**/build/**',
        # Delphi project files (XML - very noisy)
        '*.dproj',
        '*.groupproj',
        '*.dof',
        '*.cfg',
        '*.deployproj',
        # Delphi build artifacts
        '*.dcu',
        '*.res',
        '*.identcache',
        '*.local',
        '*.~*',
        # Delphi help files
        '*.hhc',
        '*.hhk',
        '*.hhp',
        # Lazarus/FPC project files
        '*.lpi',
        '*.lps',
        '*.lpk',
        '*.compiled',
        # xHarbour/Harbour build artifacts
        '*.hrb',  # Harbour portable executable
        '*.hbm',  # Harbour make file
        '*.hbc',  # Harbour build config
        'ChangeLog',  # Often auto-updated
    ]

    # Patterns to skip in diff content (hashes, checksums, CI/CD, tests, etc.)
    NOISE_PATTERNS = [
        # Hashes and checksums
        r'sha256:[a-f0-9]{64}',  # SHA256 hashes
        r'sha512:[a-f0-9]{128}',  # SHA512 hashes
        r'sha512-[A-Za-z0-9+/=]{50,}',  # Base64 SHA512
        r'sha1:[a-f0-9]{40}',  # SHA1 hashes
        r'\b[a-f0-9]{64}\b',  # Bare 64-char hex (likely hash)
        r'integrity\s*[:=]\s*["\']sha\d+-',  # npm integrity hashes
        r'"resolved":\s*"https?://',  # npm resolved URLs
        r'"version":\s*"\d+\.\d+',  # Version strings in lock files
        # GitHub Actions
        r'actions/[\w-]+@v?\d+',  # actions/checkout@v4
        r'actions/[\w-]+@[a-f0-9]{7,}',  # actions/checkout@abc1234
        r'::set-output\s+name=',  # GitHub Actions commands
        r'uses:\s+[\w-]+/[\w-]+@',  # uses: org/repo@ref
        # CI/CD patterns
        r'slsa-framework/',  # SLSA framework refs
        r'pypa/gh-action-',  # PyPA GitHub actions
        r'step-security/',  # Step security actions
        # Test assertions (common patterns)
        r'^should\s+\w+',  # "should convert...", "should throw..."
        r'assert\w*\s*\(',  # assert(), assertEqual()
        r'expect\s*\(',  # expect()
        r'describe\s*\(',  # describe()
        r'it\s*\([\'"]should',  # it('should...')
        # node_modules paths
        r'node_modules/',  # Any node_modules reference
        # Error codes and internal identifiers
        r'ERR_[A-Z_]+',  # Node.js error codes
        # URL-like test data
        r'http:/\w+',  # Malformed URLs (missing slash)
        r'https:/\w+',  # Malformed URLs (missing slash)
        # Delphi build variables (from .dproj XML files)
        r'\$\(Platform\)',
        r'\$\(BDS\w*\)',
        r'\$\(Base_\w+\)',
        r'\$\(ProjectName\)',
        r'\$\(MSBuild\w+\)',
        r'\$\(APPDATA\)\\\\Embarcadero',
        r'\$\(BDSBIN\)',
        # Delphi Android/iOS resource identifiers
        r'Android(Lib|File|Service|_)\w+',
        r'iOS_\w+\d+',
        r'iPad_\w+\d*',
        r'iPhone_\w+\d*',
        r'UWP_\w+\d*',
        r'iOSSimARM64',
        r'armeabi-v7a',
        r'arm64-v8a',
        # Delphi XML project patterns
        r'<PropertyGroup\s',
        r'<ItemGroup\s',
        r'DependencyFramework',
        r'AdditionalDebugSymbols',
        # Delphi help file patterns
        r'collapsibleArea\w*',
        r'contentEditableControl',
        r'hiddenScrollOffset',
        r'inheritanceHierarchyContent',
        r'group-\w+Section',
        r'group-\w+Header',
        r'group-\w+Content',
        r'group-\w+',  # Catch remaining group-* patterns
        r'text/sitemap',
        r'tableSection',
        r'summaryHeader',
        r'userDataCache',
        r'contentEditable',
        r'mk:@MSITStore',
        r'ms-help:',
        r'index\.html\?',
        # Delphi package/binary paths
        r'\.bpl\b',
        r'\.dcp\b',
        r'\\Binary\\',
        # SVG path data (very noisy)
        r'^M\d+[,\s]\d+\s*[LCZHVlchvz]',  # M100,80 C250...
        r'^M\d+\s+\d+h\d+v\d+H\d+z',  # M0 0h108v108H0z
        # Lazarus/FPC patterns
        r'lib/\$\(TargetCPU\)',
        r'-dUseCThreads',
        r'-dBorland',
        r'-dVer\d+',
        r'-dDelphi\d+',
        r'-dCompiler\d+',
        r'-dPURE',
        r'LCLWidgetType',
        r'\$\(ProjOutDir\)',
        r'\.lpr\b',  # Lazarus project file reference
        r'\.lpi\b',  # Lazarus project info
        r'\.lpk\b',  # Lazarus package
        # XML encoding declarations
        r'encoding=',
        r'xml version=',
        # Empty or whitespace-only strings
        r'^[\s#\r\n]+$',
        # Delphi unit file references in diffs
        r'^\w+\.pas$',
        r'^\w+\.dfm$',
        # xHarbour/Harbour patterns
        r'Update ChangeLog',  # Auto-update commits
        r'ChangeLog SVN version',
        r'HB_\w+_\w+',  # Internal HB_ constants (HB_FINITE_DBL, HB_CURLOPT_*)
        r'__GNUC__',  # Compiler flags
        r'__clang__',
        r'LONG_PTR',
        r'ULONG_PTR',
        r'MinGW',
        r'xbuild\.\w+\.ini',  # Build config files
    ]

    # File type categories for context
    FILE_CATEGORIES = {
        'ui': ['.html', '.css', '.scss', '.less', '.jsx', '.tsx', '.vue', '.svelte', '.dfm', '.fmx'],
        'config': ['.json', '.yaml', '.yml', '.toml', '.ini', '.env', '.config'],
        'docs': ['.md', '.txt', '.rst', '.doc', '.docx', '.pdf'],
        'code': ['.py', '.js', '.ts', '.go', '.java', '.cs', '.rb', '.php', '.swift', '.kt', '.pas', '.dpr', '.dpk', '.prg', '.ch'],
        'data': ['.sql', '.csv', '.xml'],
        'build': ['Makefile', 'Dockerfile', '.sh', '.bat', '.ps1', 'package.json', 'requirements.txt'],
        'test': ['test_', '_test.', '.test.', 'spec.'],
        'delphi': ['.pas', '.dpr', '.dpk', '.dfm', '.fmx', '.inc'],
        'harbour': ['.prg', '.ch', '.hbp', '.hbc', '.hbm', '.hbs']
    }

    # Patterns that indicate user-facing changes
    USER_FACING_PATTERNS = [
        # UI text patterns
        (r'["\']([^"\']{10,100})["\']', 'text_change'),  # String literals
        (r'message\s*[:=]\s*["\'](.+?)["\']', 'message_change'),
        (r'label\s*[:=]\s*["\'](.+?)["\']', 'label_change'),
        (r'title\s*[:=]\s*["\'](.+?)["\']', 'title_change'),
        (r'error\s*[:=]\s*["\'](.+?)["\']', 'error_change'),
        (r'placeholder\s*[:=]\s*["\'](.+?)["\']', 'placeholder_change'),
        # Feature toggles
        (r'enabled?\s*[:=]\s*(true|false)', 'toggle_change'),
        (r'disabled?\s*[:=]\s*(true|false)', 'toggle_change'),
        (r'show\w*\s*[:=]\s*(true|false)', 'visibility_change'),
        (r'hide\w*\s*[:=]\s*(true|false)', 'visibility_change'),
        (r'visible\s*[:=]\s*(true|false)', 'visibility_change'),
        # Settings/config
        (r'timeout\s*[:=]\s*(\d+)', 'timeout_change'),
        (r'limit\s*[:=]\s*(\d+)', 'limit_change'),
        (r'max\w*\s*[:=]\s*(\d+)', 'limit_change'),
        (r'min\w*\s*[:=]\s*(\d+)', 'limit_change'),
        # URLs and endpoints
        (r'url\s*[:=]\s*["\'](.+?)["\']', 'url_change'),
        (r'endpoint\s*[:=]\s*["\'](.+?)["\']', 'endpoint_change'),
    ]

    def __init__(self, config_path: Optional[str] = None):
        """
        Initialize the diff parser.

        Args:
            config_path: Optional path to custom config file
        """
        self.config = get_config(config_path)
        self.changes: List[Dict[str, Any]] = []
        self._keyword_map = self.config.get_all_keywords()
        # Compile noise patterns for efficiency
        self._noise_regex = [re.compile(p, re.IGNORECASE) for p in self.NOISE_PATTERNS]

    def parse_diff(self, diff_content: str, files_changed: List[Dict[str, str]],
                   commit_subject: str) -> List[Dict[str, Any]]:
        """
        Parse a diff and extract user-friendly change descriptions.

        Args:
            diff_content: Raw git diff content
            files_changed: List of files with their status (added, modified, deleted)
            commit_subject: The commit message subject

        Returns:
            List of change descriptions
        """
        changes = []

        # Filter out ignored files (lock files, generated files)
        filtered_files = [f for f in files_changed if not self._should_ignore_file(f['path'])]

        # First, try to understand from the commit message
        message_interpretation = self._interpret_commit_message(commit_subject)
        if message_interpretation:
            changes.append(message_interpretation)

        # Parse the actual diff for more details (only if not all files are ignored)
        if filtered_files:
            diff_changes = self._parse_diff_content(diff_content, filtered_files)
            changes.extend(diff_changes)

        # Analyze file-level changes (using filtered files)
        file_changes = self._analyze_file_changes(filtered_files)
        changes.extend(file_changes)

        return changes

    def _should_ignore_file(self, path: str) -> bool:
        """Check if a file should be ignored (lock files, generated files, test files)."""
        from pathlib import Path
        import fnmatch

        p = Path(path)
        filename = p.name
        path_lower = path.lower()

        # Check for test directories in path (handles **/__tests__/** patterns)
        test_dir_patterns = ['__tests__', '/test/', '/tests/', '/spec/', '/specs/']
        if any(pattern in path_lower for pattern in test_dir_patterns):
            return True

        # Check for test file suffixes
        test_suffixes = ['.test.ts', '.test.js', '.test.tsx', '.test.jsx',
                        '.spec.ts', '.spec.js', '.spec.tsx', '.spec.jsx',
                        '_test.py', '_test.go']
        if any(filename.lower().endswith(suffix) for suffix in test_suffixes):
            return True
        if filename.lower().startswith('test_') and filename.endswith('.py'):
            return True

        # Check for CI/CD directories
        if '/.github/workflows/' in path or path.startswith('.github/workflows/'):
            return True

        # Check for generated/vendor directories
        vendor_patterns = ['/node_modules/', '/vendor/', '/dist/', '/build/']
        if any(pattern in path for pattern in vendor_patterns):
            return True

        # Standard fnmatch for simple patterns
        for pattern in self.IGNORE_FILES:
            # Skip ** patterns (handled above)
            if '**' in pattern:
                continue
            if fnmatch.fnmatch(filename, pattern):
                return True
            if fnmatch.fnmatch(path, pattern):
                return True

        return False

    def _is_noise_content(self, text: str) -> bool:
        """Check if text matches noise patterns (hashes, checksums, etc.)."""
        for regex in self._noise_regex:
            if regex.search(text):
                return True
        return False

    def _interpret_commit_message(self, subject: str) -> Optional[Dict[str, Any]]:
        """
        Interpret the commit message into a user-friendly description.

        Args:
            subject: Commit message subject line

        Returns:
            Change description dictionary or None
        """
        if not subject:
            return None

        # Clean up common prefixes
        clean_subject = subject

        # Remove conventional commit prefixes
        clean_subject = re.sub(r'^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\(.+?\))?!?:\s*', '', clean_subject, flags=re.IGNORECASE)

        # Remove Delphi-style prefixes like [Library], [Tests], [API], [FMX Render], etc.
        clean_subject = re.sub(r'^\[[\w\s]+\]\s*', '', clean_subject)

        # Remove ticket references
        clean_subject = re.sub(r'\[?[A-Z]+-\d+\]?\s*', '', clean_subject)
        clean_subject = re.sub(r'#\d+\s*', '', clean_subject)
        # Remove PR references at end like "(#106)"
        clean_subject = re.sub(r'\s*\(#\d+\)\s*$', '', clean_subject)
        # Clean up empty parentheses left over
        clean_subject = re.sub(r'\s*\(\s*\)\s*', '', clean_subject)

        # Remove WIP, TODO prefixes
        clean_subject = re.sub(r'^(WIP|TODO|FIXME|HACK):\s*', '', clean_subject, flags=re.IGNORECASE)

        clean_subject = clean_subject.strip()

        if not clean_subject or len(clean_subject) < 5:
            return None

        # Determine category from original subject
        category = self._categorize_from_message(subject)

        return {
            'description': self._humanize_description(clean_subject),
            'category': category,
            'source': 'commit_message',
            'confidence': 'medium',
            'raw': subject
        }

    def _categorize_from_message(self, message: str) -> str:
        """Determine category from commit message."""
        message_lower = message.lower()

        # Check for Delphi-style prefixes like [Library], [Tests], [API]
        delphi_prefix_match = re.match(r'^\[([\w\s]+)\]', message)
        if delphi_prefix_match:
            prefix = delphi_prefix_match.group(1).lower()
            delphi_categories = {
                'library': 'change',
                'api': 'change',
                'tests': 'other',
                'test': 'other',
                'fmx render': 'enhancement',
                'vcl render': 'enhancement',
                'controls': 'enhancement',
                'setup': 'other',
                'documentation': 'other',
                'docs': 'other',
                'samples': 'other',
                'sample': 'other',
            }
            if prefix in delphi_categories:
                return delphi_categories[prefix]

        # Check for conventional commit prefixes
        if re.match(r'^feat(\(.+?\))?!?:', message_lower):
            return 'feature'
        if re.match(r'^fix(\(.+?\))?!?:', message_lower):
            return 'bugfix'
        if re.match(r'^sec(urity)?(\(.+?\))?!?:', message_lower):
            return 'security'
        if re.match(r'^(perf|enhance|improve)(\(.+?\))?:', message_lower):
            return 'enhancement'
        if re.match(r'^(docs|doc)(\(.+?\))?:', message_lower):
            return 'other'
        if re.match(r'^(refactor|style|chore|build|ci|test)(\(.+?\))?:', message_lower):
            return 'other'
        if re.match(r'^revert(\(.+?\))?:', message_lower):
            return 'change'
        # Dependency bumps - group together
        if re.match(r'^build\(deps(-dev)?\):', message_lower):
            return 'dependency'

        # Delphi/CEF version updates (common pattern: "Update to CEF X.Y.Z")
        if re.match(r'^update\s+to\s+(cef|chromium|skia|indy|synapse)\s+\d+', message_lower):
            return 'dependency'

        # Check for keywords
        if any(word in message_lower for word in ['add', 'new', 'create', 'implement', 'introduce']):
            return 'feature'
        if any(word in message_lower for word in ['fix', 'bug', 'issue', 'error', 'crash', 'resolve', 'pacify']):
            return 'bugfix'
        if any(word in message_lower for word in ['security', 'cve', 'vulnerability', 'exploit']):
            return 'security'
        if any(word in message_lower for word in ['improve', 'enhance', 'update', 'upgrade', 'optimize', 'better']):
            return 'enhancement'
        if any(word in message_lower for word in ['remove', 'delete', 'deprecate']):
            return 'change'
        if any(word in message_lower for word in ['breaking', 'migrate', 'migration']):
            return 'breaking'
        if any(word in message_lower for word in ['bump', 'deps', 'dependency']):
            return 'dependency'

        return 'other'

    def _humanize_description(self, text: str) -> str:
        """
        Convert technical description to human-friendly language.

        Args:
            text: Technical description

        Returns:
            Human-friendly description
        """
        # Capitalize first letter
        if text:
            text = text[0].upper() + text[1:]

        # Remove technical terms and make more readable
        replacements = [
            (r'\bimpl(?:ement(?:ed|s|ation)?)?', 'Added'),
            (r'\brefactor(?:ed|ing)?', 'Improved'),
            (r'\boptimiz(?:e|ed|ation)', 'Improved speed of'),
            (r'\bapi\b', 'system'),
            (r'\bendpoint\b', 'feature'),
            (r'\bmodule\b', 'component'),
            (r'\bcomponent\b', 'feature'),
            (r'\bhandler\b', 'processor'),
            (r'\bcallback\b', 'action'),
            (r'\butil(?:ity|s)?\b', 'helper'),
            (r'\binit(?:ialize)?(?:d)?\b', 'set up'),
            (r'\bconfig(?:uration)?\b', 'settings'),
            (r'\bparam(?:eter)?s?\b', 'options'),
            (r'\bauth(?:entication)?\b', 'login'),
            (r'\bvalidat(?:e|ion)\b', 'check'),
        ]

        for pattern, replacement in replacements:
            text = re.sub(pattern, replacement, text, flags=re.IGNORECASE)

        return text.strip()

    def _parse_diff_content(self, diff_content: str, files_changed: List[Dict[str, str]]) -> List[Dict[str, Any]]:
        """
        Parse actual diff content for user-facing changes.

        Args:
            diff_content: Raw diff content
            files_changed: List of changed files

        Returns:
            List of detected changes
        """
        changes = []

        if not diff_content:
            return changes

        # Look for user-facing patterns in additions
        additions = self._extract_additions(diff_content)

        for line in additions:
            # Skip lines that are noise (hashes, checksums, etc.)
            if self._is_noise_content(line):
                continue

            for pattern, change_type in self.USER_FACING_PATTERNS:
                match = re.search(pattern, line, re.IGNORECASE)
                if match:
                    # Found a user-facing change
                    value = match.group(1) if match.groups() else match.group(0)

                    # Skip if it looks like code (has function calls, brackets, etc.)
                    if self._looks_like_code(value):
                        continue

                    # Skip if the matched value is noise
                    if self._is_noise_content(value):
                        continue

                    description = self._describe_pattern_change(change_type, value, line)
                    if description:
                        changes.append({
                            'description': description,
                            'category': self._category_from_change_type(change_type),
                            'source': 'diff_analysis',
                            'confidence': 'high',
                            'raw': line.strip()
                        })

        return changes

    def _extract_additions(self, diff_content: str) -> List[str]:
        """Extract added lines from diff, filtering out test file content."""
        additions = []
        current_file = None
        skip_current_file = False

        for line in diff_content.split('\n'):
            # Detect file being diffed
            if line.startswith('diff --git'):
                # Extract file path: "diff --git a/path/file b/path/file"
                parts = line.split(' b/')
                if len(parts) > 1:
                    current_file = parts[1]
                    skip_current_file = self._should_ignore_file(current_file)
                else:
                    skip_current_file = False
            elif line.startswith('+') and not line.startswith('+++'):
                # Only add if current file is not ignored
                if not skip_current_file:
                    additions.append(line[1:])  # Remove the '+' prefix

        return additions

    def _looks_like_code(self, text: str) -> bool:
        """Check if text looks like code rather than user-facing content."""
        code_patterns = [
            r'\w+\s*\(',  # Function calls
            r'\{\s*\}',  # Empty braces
            r'\[\s*\]',  # Empty brackets
            r'=>',  # Arrow functions
            r'->',  # Method chains
            r'\$\w+',  # Variables
            r'^\d+$',  # Just numbers
            r'^[a-z_]+$',  # Just identifiers
            r'^\s*$',  # Empty/whitespace
            r'^\.\.+$',  # Just dots
            r'^\.\.$',  # ".."
            r'^[A-Z_]{3,}$',  # ALL_CAPS constants
            r'::\w+',  # Ruby/C++ scope resolution
            r'@\w+/',  # npm scoped packages
            r'^[\w-]+@[\d\.]+',  # package@version
            r'BSD-\d+-Clause',  # License identifiers
            r'^peerDependencies$',  # package.json fields
            r'^node_modules',  # node_modules paths
            r'^\d+\.\%$',  # Percentage like "33.%"
            r'^\\n$',  # Escaped newlines
        ]

        for pattern in code_patterns:
            if re.search(pattern, text):
                return True

        # Too short to be meaningful text
        if len(text) < 3:
            return True

        # Looks like a test assertion
        if text.lower().startswith('should '):
            return True

        # Looks like a file path
        if '/' in text and (text.count('/') > 2 or text.startswith('/')):
            return True

        # Looks like HTML entities
        if '&#x' in text or '&amp;' in text:
            return True

        # Looks like spam/promotional (common patterns)
        spam_keywords = ['buy instagram', 'ставки', 'betting', 'casino', 'followers',
                        'best route planning', 'route optimization software']
        if any(kw in text.lower() for kw in spam_keywords):
            return True

        # Looks like CI/CD step names
        ci_step_patterns = [
            r'^set up \w+',  # "Set up Python"
            r'^checkout\s',  # "Checkout repository"
            r'^install\s',  # "Install dependencies"
            r'^build\s',  # "Build dists"
            r'^generate\s',  # "Generate hashes"
            r'^download\s',  # "Download artifact"
            r'^upload\s',  # "Upload artifact"
        ]
        for pattern in ci_step_patterns:
            if re.match(pattern, text.lower()):
                return True

        # Looks like test data (patterns with login/password/machine)
        if any(kw in text.lower() for kw in ['login ', 'password ', 'machine ']):
            if '\\n' in text or '\n' in text:
                return True

        # Looks like Python classifiers
        if text.startswith('Programming Language'):
            return True

        # Looks like CSS classes
        if re.match(r'^[a-z]+-[a-z]+-?[a-z]*$', text):  # btn-primary, fas-icon
            return True

        # Looks like error/debug code
        if re.match(r'^(Invalid|Error|Unexpected|Could not|Unable to)\s', text):
            return True

        return False

    def _describe_pattern_change(self, change_type: str, value: str, context: str) -> Optional[str]:
        """
        Create a description for a pattern-matched change.

        Args:
            change_type: Type of change detected
            value: The matched value
            context: Full line context

        Returns:
            Human-friendly description or None
        """
        descriptions = {
            'text_change': f'Updated text: "{value[:50]}..."' if len(value) > 50 else f'Updated text: "{value}"',
            'message_change': f'Changed message to: "{value[:50]}..."' if len(value) > 50 else f'Changed message: "{value}"',
            'label_change': f'Updated label: "{value}"',
            'title_change': f'Changed title to: "{value}"',
            'error_change': f'Improved error message: "{value[:50]}..."' if len(value) > 50 else None,
            'placeholder_change': f'Updated placeholder text: "{value}"',
            'toggle_change': 'Enabled feature' if value.lower() == 'true' else 'Disabled feature',
            'visibility_change': 'Made element visible' if value.lower() == 'true' else 'Hidden element',
            'timeout_change': f'Adjusted timeout to {value} seconds',
            'limit_change': f'Changed limit to {value}',
            'url_change': None,  # Don't expose URLs
            'endpoint_change': None,  # Don't expose endpoints
        }

        return descriptions.get(change_type)

    def _category_from_change_type(self, change_type: str) -> str:
        """Map change type to category."""
        category_map = {
            'text_change': 'change',
            'message_change': 'enhancement',
            'label_change': 'enhancement',
            'title_change': 'change',
            'error_change': 'enhancement',
            'placeholder_change': 'enhancement',
            'toggle_change': 'feature',
            'visibility_change': 'change',
            'timeout_change': 'enhancement',
            'limit_change': 'change',
        }
        return category_map.get(change_type, 'other')

    def _analyze_file_changes(self, files_changed: List[Dict[str, str]]) -> List[Dict[str, Any]]:
        """
        Analyze file-level changes for high-level descriptions.

        Args:
            files_changed: List of changed files with status

        Returns:
            List of file-based change descriptions
        """
        changes = []

        # Group by category
        added_files = [f for f in files_changed if f['status'] == 'added']
        deleted_files = [f for f in files_changed if f['status'] == 'deleted']

        # Check for new features (new UI files, new screens)
        new_ui_files = [f for f in added_files if self._is_ui_file(f['path'])]
        if new_ui_files:
            for f in new_ui_files[:3]:  # Limit to 3
                name = self._get_friendly_name(f['path'])
                if name:
                    changes.append({
                        'description': f'Added new {name}',
                        'category': 'feature',
                        'source': 'file_analysis',
                        'confidence': 'medium',
                        'raw': f['path']
                    })

        # Check for removed features
        removed_ui_files = [f for f in deleted_files if self._is_ui_file(f['path'])]
        if removed_ui_files:
            for f in removed_ui_files[:3]:
                name = self._get_friendly_name(f['path'])
                if name:
                    changes.append({
                        'description': f'Removed {name}',
                        'category': 'change',
                        'source': 'file_analysis',
                        'confidence': 'medium',
                        'raw': f['path']
                    })

        return changes

    def _is_ui_file(self, path: str) -> bool:
        """Check if file is UI-related."""
        path_lower = path.lower()
        for ext in self.FILE_CATEGORIES['ui']:
            if path_lower.endswith(ext):
                return True
        return False

    def _get_friendly_name(self, path: str) -> Optional[str]:
        """Extract a friendly name from file path."""
        filename = Path(path).stem

        # Skip common non-descriptive names
        skip_names = ['index', 'main', 'app', 'utils', 'helpers', 'common', 'types', 'constants']
        if filename.lower() in skip_names:
            return None

        # Convert to readable name
        # CamelCase -> separate words
        name = re.sub(r'([a-z])([A-Z])', r'\1 \2', filename)
        # snake_case -> separate words
        name = name.replace('_', ' ').replace('-', ' ')
        # Capitalize
        name = name.title()

        return name if len(name) > 2 else None

    def get_net_changes(self, all_changes: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        """
        Filter changes to only include net changes (eliminate flip-flops).

        This is a placeholder - actual implementation would need to track
        the same item across commits and compare initial vs final state.

        Args:
            all_changes: All detected changes

        Returns:
            Filtered list of net changes
        """
        # Deduplicate by description
        seen = set()
        unique_changes = []

        for change in all_changes:
            desc = change['description'].lower()
            if desc not in seen:
                seen.add(desc)
                unique_changes.append(change)

        return unique_changes
