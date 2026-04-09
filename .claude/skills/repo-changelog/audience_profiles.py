"""
Audience Profiles for Changelog Generation

Defines different output styles and filtering rules for:
- end-users (default): User-facing changes only, plain language
- developers: Full technical detail, all changes
- executives: High-level summary, business impact
"""

from typing import Dict, List, Set, Tuple


# Audience profile definitions
AUDIENCE_PROFILES = {
    'end-users': {
        'description': 'User-facing changes only, plain language, no technical terms',
        'include_categories': {'feature', 'enhancement', 'bugfix', 'breaking', 'security'},
        'exclude_categories': {'dependency', 'other'},
        'include_internal': False,
        'max_description_length': 100,
        'show_file_paths': False,
        'show_pr_references': False,
        'group_similar': True,
    },
    'developers': {
        'description': 'Full technical detail, all changes, code references',
        'include_categories': {'feature', 'enhancement', 'bugfix', 'breaking', 'security', 'dependency', 'change', 'other'},
        'exclude_categories': set(),
        'include_internal': True,
        'max_description_length': 200,
        'show_file_paths': True,
        'show_pr_references': True,
        'group_similar': False,
    },
    'executives': {
        'description': 'High-level summary, business impact, metrics',
        'include_categories': {'feature', 'enhancement', 'bugfix', 'breaking', 'security'},
        'exclude_categories': {'dependency', 'other'},
        'include_internal': False,
        'max_description_length': 50,
        'show_file_paths': False,
        'show_pr_references': False,
        'group_similar': True,
        'aggregate_counts': True,
    },
}

# File paths that indicate user-facing changes
USER_FACING_PATHS = [
    'ui/', 'components/', 'pages/', 'views/', 'screens/',
    'templates/', 'layouts/', 'widgets/', 'forms/',
    # Delphi/FMX
    '.dfm', '.fmx',
    # Web
    '.html', '.css', '.scss',
    # Mobile
    'ios/', 'android/',
]

# File paths that indicate internal/technical changes
INTERNAL_PATHS = [
    'utils/', 'helpers/', 'internal/', 'lib/', 'core/',
    'test/', 'tests/', 'spec/', '__tests__/',
    'migrations/', 'scripts/', 'tools/',
    '.github/', 'ci/', 'build/',
]

# Term replacements for end-users (technical -> plain language)
TERM_REPLACEMENTS = {
    # Technical concepts
    r'\bAPI\b': 'service',
    r'\bAPIendpoint\b': 'feature',
    r'\bendpoint\b': 'feature',
    r'\bdatabase\b': 'data',
    r'\bDB\b': 'data',
    r'\bcache\b': 'temporary storage',
    r'\bcaching\b': 'speed optimization',
    r'\bquery\b': 'request',
    r'\bqueries\b': 'requests',

    # Authentication
    r'\bauthentication\b': 'login',
    r'\bauth\b': 'login',
    r'\bOAuth\b': 'login',
    r'\bJWT\b': 'session',
    r'\btoken\b': 'session',
    r'\bsession\b': 'login session',

    # Code terms
    r'\brefactor(?:ed|ing)?\b': 'improved',
    r'\boptimiz(?:e|ed|ing|ation)\b': 'speed improvement',
    r'\bmigrat(?:e|ed|ion)\b': 'update',
    r'\bdeprecate[d]?\b': 'phase out',
    r'\bmodule\b': 'component',
    r'\bcomponent\b': 'feature',
    r'\bhandler\b': 'processor',
    r'\bcallback\b': 'response',
    r'\bmiddleware\b': 'processing',
    r'\bwebhook\b': 'notification',

    # Infrastructure
    r'\bserver\b': 'system',
    r'\bbackend\b': 'system',
    r'\bfrontend\b': 'interface',
    r'\binfrastructure\b': 'system',
    r'\bdeployment\b': 'release',
    r'\bCI/CD\b': 'automation',
    r'\bpipeline\b': 'process',

    # Errors
    r'\bexception\b': 'error',
    r'\bstack trace\b': 'error details',
    r'\bbug\b': 'issue',
    r'\brace condition\b': 'timing issue',
    r'\bmemory leak\b': 'performance issue',
    r'\bcrash\b': 'unexpected shutdown',
}

# Executive category mappings (technical -> business)
EXECUTIVE_CATEGORIES = {
    'feature': 'New Capabilities',
    'enhancement': 'Improvements',
    'bugfix': 'Stability & Fixes',
    'security': 'Security Updates',
    'breaking': 'Important Changes',
    'dependency': 'Infrastructure',
    'other': 'Maintenance',
    'change': 'Updates',
}

# End-user friendly category names
END_USER_CATEGORIES = {
    'feature': "What's New",
    'enhancement': 'Improvements',
    'bugfix': 'Fixes',
    'security': 'Security',
    'breaking': 'Important Changes',
}

# Developer category names (standard)
DEVELOPER_CATEGORIES = {
    'feature': 'New Features',
    'enhancement': 'Enhancements',
    'bugfix': 'Bug Fixes',
    'security': 'Security',
    'breaking': 'Breaking Changes',
    'dependency': 'Dependencies',
    'other': 'Other',
    'change': 'Changes',
}


def get_profile(audience: str) -> Dict:
    """Get the profile configuration for an audience."""
    return AUDIENCE_PROFILES.get(audience, AUDIENCE_PROFILES['end-users'])


def get_included_categories(audience: str) -> Set[str]:
    """Get the set of categories to include for an audience."""
    profile = get_profile(audience)
    return profile.get('include_categories', set())


def get_category_names(audience: str) -> Dict[str, str]:
    """Get the category display names for an audience."""
    if audience == 'executives':
        return EXECUTIVE_CATEGORIES
    elif audience == 'developers':
        return DEVELOPER_CATEGORIES
    else:
        return END_USER_CATEGORIES


def get_term_replacements() -> Dict[str, str]:
    """Get the term replacements for end-user language."""
    return TERM_REPLACEMENTS


def is_user_facing_path(path: str) -> bool:
    """Check if a file path indicates user-facing changes."""
    path_lower = path.lower()
    return any(pattern in path_lower for pattern in USER_FACING_PATHS)


def is_internal_path(path: str) -> bool:
    """Check if a file path indicates internal/technical changes."""
    path_lower = path.lower()
    return any(pattern in path_lower for pattern in INTERNAL_PATHS)


def should_include_for_audience(change: Dict, audience: str) -> bool:
    """
    Determine if a change should be included for the target audience.

    Args:
        change: Change dictionary with 'category', 'files', etc.
        audience: Target audience ('end-users', 'developers', 'executives')

    Returns:
        True if the change should be included
    """
    profile = get_profile(audience)
    category = change.get('category', 'other')

    # Check category inclusion
    if category not in profile.get('include_categories', set()):
        return False

    # For end-users and executives, filter out internal-only changes
    if not profile.get('include_internal', True):
        files = change.get('files', [])
        if files:
            # If all files are internal, exclude the change
            all_internal = all(is_internal_path(f) for f in files)
            any_user_facing = any(is_user_facing_path(f) for f in files)

            # For bugfixes, prefer user-facing ones
            if category == 'bugfix' and all_internal and not any_user_facing:
                # Check if description suggests user impact
                desc = change.get('description', '').lower()
                user_impact_words = ['user', 'display', 'show', 'click', 'button',
                                    'screen', 'page', 'form', 'input', 'output',
                                    'error message', 'notification', 'ui', 'interface']
                if not any(word in desc for word in user_impact_words):
                    return False

    return True
