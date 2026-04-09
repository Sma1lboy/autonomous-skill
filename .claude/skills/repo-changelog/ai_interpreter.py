"""
AI-powered diff interpreter module.
Uses Claude or other LLMs to interpret code changes into user-friendly descriptions.

Integrates with config.yaml for prompt templates and settings.
"""

import re
import json
from typing import Dict, List, Any, Optional, Callable
from pathlib import Path

# Import config loader
try:
    from .config_loader import get_config
except ImportError:
    from config_loader import get_config


class AIInterpreter:
    """
    Uses AI to interpret code diffs into user-friendly descriptions.

    Features:
    - Configurable prompt templates
    - Size limits to avoid token overflow
    - Fallback to pattern-based interpretation
    - Caching for repeated requests
    - Multiple AI provider support (designed for Claude)
    - Audience-specific prompts (end-users, developers, executives)
    """

    def __init__(self, config_path: Optional[str] = None,
                 ai_client: Optional[Any] = None,
                 audience: str = 'end-users'):
        """
        Initialize the AI interpreter.

        Args:
            config_path: Optional path to custom config file
            ai_client: Optional AI client instance (e.g., Anthropic client)
            audience: Target audience ('end-users', 'developers', 'executives')
        """
        self.config = get_config(config_path)
        self.ai_client = ai_client
        self.audience = audience
        self._cache: Dict[str, str] = {}

        # Load settings from config
        self.enabled = self.config.get('ai_interpretation', 'enabled', default=True)
        self.max_diff_size = self.config.get('ai_interpretation', 'max_diff_size', default=5000)
        self.max_files = self.config.get('ai_interpretation', 'max_files_per_commit', default=10)
        self.fallback_enabled = self.config.get('ai_interpretation', 'fallback_to_patterns', default=True)

        # Load prompt template based on audience
        self.prompt_template = self._get_prompt_for_audience(audience)

    def _get_prompt_for_audience(self, audience: str) -> str:
        """Get prompt template for the target audience."""
        if audience == 'developers':
            return self._get_developer_prompt()
        elif audience == 'executives':
            return self._get_executive_prompt()
        else:  # end-users (default)
            return self._get_end_user_prompt()

    def _get_end_user_prompt(self) -> str:
        """Prompt for end-user audience."""
        return """Analyze this code change and describe what it does in ONE sentence.

Rules:
- Write for END USERS who don't know programming
- Do NOT mention: function names, variable names, file paths, class names, APIs
- Do NOT use technical jargon (no "refactor", "migrate", "endpoint", "database")
- Focus on what the USER will experience differently
- Use simple language like "You can now..." or "Fixed an issue where..."
- If purely internal with no user impact, respond with: "INTERNAL_ONLY"
- Keep response under 80 characters

Commit message: {commit_message}
Files changed: {files_changed}

Diff (first 2000 chars):
```
{diff_content}
```

User-friendly description:"""

    def _get_developer_prompt(self) -> str:
        """Prompt for developer audience."""
        return """Analyze this code change and describe what it does in ONE sentence.

Rules:
- Write for DEVELOPERS who understand code
- Be technically accurate - mention affected components/modules
- Include relevant technical details (API changes, breaking changes, etc.)
- Keep response under 150 characters
- Use precise technical terminology

Commit message: {commit_message}
Files changed: {files_changed}

Diff (first 2000 chars):
```
{diff_content}
```

Technical description:"""

    def _get_executive_prompt(self) -> str:
        """Prompt for executive audience."""
        return """Analyze this code change and provide a ONE-LINE business summary.

Rules:
- Write for EXECUTIVES who care about business impact
- Focus on: customer value, revenue impact, risk reduction, efficiency gains
- Categorize as one of: New Capability | Improvement | Fix | Infrastructure
- Do NOT use technical terms
- Maximum 15 words
- Example: "New Capability: Customer export feature enables bulk data downloads"
- If purely internal/technical with no business impact, respond with: "INTERNAL_ONLY"

Commit message: {commit_message}
Files changed: {files_changed}

Business summary:"""

    def _get_default_prompt(self) -> str:
        """Get default prompt template (end-users)."""
        return self._get_end_user_prompt()

    def interpret_commit(self, commit: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """
        Interpret a single commit using AI.

        Args:
            commit: Commit dictionary with 'subject', 'diff', 'files_changed'

        Returns:
            Change dictionary or None if interpretation failed
        """
        if not self.enabled:
            return None

        # Check cache first
        cache_key = self._get_cache_key(commit)
        if cache_key in self._cache:
            return {
                'description': self._cache[cache_key],
                'category': self._categorize_description(self._cache[cache_key]),
                'source': 'ai_cached',
                'confidence': 'high'
            }

        # Prepare diff (truncate if too large)
        diff_content = self._prepare_diff(commit.get('diff', ''))
        files_list = self._format_files_list(commit.get('files_changed', []))

        # Skip if no meaningful content
        if not diff_content and not commit.get('subject'):
            return None

        # Build prompt
        prompt = self.prompt_template.format(
            commit_message=commit.get('subject', 'No message'),
            files_changed=files_list,
            diff_content=diff_content or 'No diff available'
        )

        # Call AI
        try:
            response = self._call_ai(prompt)
            if response:
                # Clean and validate response
                description = self._clean_response(response)
                if description and not self._is_internal_only(description):
                    self._cache[cache_key] = description
                    return {
                        'description': description,
                        'category': self._categorize_description(description),
                        'source': 'ai_interpretation',
                        'confidence': 'high',
                        'raw': commit.get('subject', '')
                    }
        except Exception as e:
            # Log error but don't fail
            pass

        # Fallback to pattern-based if enabled
        if self.fallback_enabled:
            return self._fallback_interpret(commit)

        return None

    def interpret_batch(self, commits: List[Dict[str, Any]],
                        progress_callback: Optional[Callable[[int, int], None]] = None) -> List[Dict[str, Any]]:
        """
        Interpret multiple commits.

        Args:
            commits: List of commit dictionaries
            progress_callback: Optional callback(current, total) for progress updates

        Returns:
            List of change dictionaries
        """
        changes = []
        total = len(commits)

        for i, commit in enumerate(commits):
            if progress_callback:
                progress_callback(i + 1, total)

            result = self.interpret_commit(commit)
            if result:
                changes.append(result)

        return changes

    def _prepare_diff(self, diff: str) -> str:
        """Prepare diff for AI, truncating if necessary."""
        if not diff:
            return ''

        # Remove binary file markers
        diff = re.sub(r'Binary files .* differ\n?', '', diff)

        # Truncate if too large
        if len(diff) > self.max_diff_size:
            # Try to truncate at a file boundary
            truncated = diff[:self.max_diff_size]
            last_file_marker = truncated.rfind('\ndiff --git')
            if last_file_marker > self.max_diff_size // 2:
                truncated = truncated[:last_file_marker]
            return truncated + '\n\n[... diff truncated for size ...]'

        return diff

    def _format_files_list(self, files: List[Dict[str, str]]) -> str:
        """Format files list for prompt."""
        if not files:
            return 'No files'

        # Limit number of files
        display_files = files[:self.max_files]
        result = []

        for f in display_files:
            status = f.get('status', 'modified')
            path = f.get('path', 'unknown')
            # Extract just filename for cleaner display
            filename = Path(path).name
            result.append(f"{status}: {filename}")

        if len(files) > self.max_files:
            result.append(f"... and {len(files) - self.max_files} more files")

        return ', '.join(result)

    def _call_ai(self, prompt: str) -> Optional[str]:
        """
        Call the AI model.

        This is designed to work with Claude but can be adapted.
        If no AI client is provided, returns None.
        """
        if not self.ai_client:
            return None

        try:
            # Anthropic Claude API format
            if hasattr(self.ai_client, 'messages'):
                response = self.ai_client.messages.create(
                    model="claude-3-haiku-20240307",  # Fast, cheap model for interpretations
                    max_tokens=100,
                    messages=[{"role": "user", "content": prompt}]
                )
                return response.content[0].text

            # OpenAI-style API
            elif hasattr(self.ai_client, 'chat'):
                response = self.ai_client.chat.completions.create(
                    model="gpt-3.5-turbo",
                    max_tokens=100,
                    messages=[{"role": "user", "content": prompt}]
                )
                return response.choices[0].message.content

        except Exception as e:
            # Return None on any error, fallback will handle it
            return None

        return None

    def _clean_response(self, response: str) -> str:
        """Clean AI response for use in changelog."""
        if not response:
            return ''

        # Strip whitespace
        clean = response.strip()

        # Remove quotes if wrapped
        if clean.startswith('"') and clean.endswith('"'):
            clean = clean[1:-1]
        if clean.startswith("'") and clean.endswith("'"):
            clean = clean[1:-1]

        # Capitalize first letter
        if clean and clean[0].islower():
            clean = clean[0].upper() + clean[1:]

        # Remove trailing period
        clean = clean.rstrip('.')

        # Limit length
        if len(clean) > 200:
            clean = clean[:197] + '...'

        return clean

    def _is_internal_only(self, description: str) -> bool:
        """Check if description indicates internal-only change."""
        internal_indicators = [
            'internal improvement',
            'internal change',
            'no user impact',
            'internal only',
            'code cleanup',
            'refactoring only'
        ]

        desc_lower = description.lower()
        return any(indicator in desc_lower for indicator in internal_indicators)

    def _categorize_description(self, description: str) -> str:
        """Categorize a description based on keywords."""
        desc_lower = description.lower()

        # Feature keywords
        if any(kw in desc_lower for kw in ['added', 'new', 'now', 'can now', 'introducing']):
            return 'feature'

        # Bug fix keywords
        if any(kw in desc_lower for kw in ['fixed', 'resolved', 'no longer', 'corrected']):
            return 'bugfix'

        # Enhancement keywords
        if any(kw in desc_lower for kw in ['improved', 'faster', 'better', 'enhanced', 'optimized']):
            return 'enhancement'

        # Change keywords
        if any(kw in desc_lower for kw in ['changed', 'updated', 'modified', 'replaced']):
            return 'change'

        # Breaking change keywords
        if any(kw in desc_lower for kw in ['breaking', 'removed', 'deprecated', 'no longer supported']):
            return 'breaking'

        return 'other'

    def _fallback_interpret(self, commit: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """
        Fallback interpretation using pattern matching.

        Used when AI is unavailable or fails.
        """
        subject = commit.get('subject', '')
        if not subject:
            return None

        # Clean up the subject
        clean = subject

        # Remove conventional commit prefix
        clean = re.sub(r'^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\(.+?\))?!?:\s*', '', clean, flags=re.IGNORECASE)

        # Remove ticket references
        clean = re.sub(r'\[?[A-Z]+-\d+\]?\s*', '', clean)
        clean = re.sub(r'#\d+\s*', '', clean)

        # Humanize common patterns
        replacements = [
            (r'\bimpl\b', 'Added'),
            (r'\brefactor\b', 'Improved'),
            (r'\bapi\b', 'system'),
            (r'\bendpoint\b', 'feature'),
            (r'\bconfig\b', 'settings'),
        ]

        for pattern, replacement in replacements:
            clean = re.sub(pattern, replacement, clean, flags=re.IGNORECASE)

        clean = clean.strip()

        if len(clean) < 5:
            return None

        # Capitalize
        if clean[0].islower():
            clean = clean[0].upper() + clean[1:]

        return {
            'description': clean,
            'category': self._categorize_description(clean),
            'source': 'pattern_fallback',
            'confidence': 'medium',
            'raw': subject
        }

    def _get_cache_key(self, commit: Dict[str, Any]) -> str:
        """Generate cache key for a commit."""
        return commit.get('hash', commit.get('subject', ''))[:40]

    def set_ai_client(self, client: Any) -> None:
        """Set or update the AI client."""
        self.ai_client = client

    def clear_cache(self) -> None:
        """Clear the interpretation cache."""
        self._cache = {}


class MockAIClient:
    """
    Mock AI client for testing.

    Returns predefined responses based on patterns.
    """

    def __init__(self):
        self.messages = self

    def create(self, **kwargs) -> Any:
        """Mock create method."""
        prompt = kwargs.get('messages', [{}])[0].get('content', '')

        # Simple pattern matching for mock responses
        if 'button' in prompt.lower():
            response = "Added new button to the interface"
        elif 'fix' in prompt.lower() or 'bug' in prompt.lower():
            response = "Fixed an issue that could cause problems"
        elif 'performance' in prompt.lower() or 'speed' in prompt.lower():
            response = "Improved application speed"
        elif 'error' in prompt.lower():
            response = "Better error messages for users"
        else:
            response = "Internal improvement"

        # Return mock response object
        class MockResponse:
            def __init__(self, text):
                self.content = [type('obj', (object,), {'text': text})()]

        return MockResponse(response)
