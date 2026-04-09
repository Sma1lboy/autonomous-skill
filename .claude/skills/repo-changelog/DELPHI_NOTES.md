# Delphi Project Analysis Notes

Analysis of 6 Delphi repositories to improve changelog generation.

---

## Repositories Analyzed

| Repository | Focus | Commit Style |
|------------|-------|--------------|
| skia4delphi | Graphics library | `[Category] Description` |
| Delphi-Game-Engine | Game framework | Standard with issue refs |
| Delphi-samples | Code samples | Descriptive |
| delphi-demos | Demo projects | `+` prefix for additions |
| DelphiDemos | Various demos | Short descriptions |
| scalemm | Memory manager | Technical descriptions |

---

## Key Findings

### 1. Delphi File Extensions to Ignore

**Project Files (XML/binary - generate lots of noise):**
- `.dproj` - Delphi project file (XML)
- `.groupproj` - Project group file (XML)
- `.dof` - Legacy project options
- `.cfg` - Project configuration
- `.deployproj` - Deployment project

**Build Artifacts:**
- `.dcu` - Compiled unit
- `.res` - Compiled resources
- `.identcache` - IDE cache
- `.local` - Local settings
- `*.~*` - Backup files

**Help Files (generate HTML noise):**
- `.hhc` - Help contents
- `.hhk` - Help index
- `.hhp` - Help project

### 2. Delphi-Specific Spam Patterns

**Build Variables (from .dproj files):**
```
$(Platform)
$(BDSBIN)
$(Base_iOSDevice64)
$(Base_Linux64)
$(ProjectName)
$(APPDATA)\Embarcadero
$(BDS)\bin\Artwork
$(MSBuildProjectName)
```

**Android/iOS Resource Names:**
```
AndroidLibnativeArmeabiFile
AndroidFileProvider
AndroidServiceOutput_Android32
Android_AdaptiveIcon*
Android_SplashImage*
Android_VectorizedSplash*
iOS_AppStore1024
iPad_Launch*
iPhone_Setting*
UWP_DelphiLogo*
```

**Help File Patterns:**
```
collapsibleArea*
contentEditableControl
userDataCache
hiddenScrollOffset
inheritanceHierarchyContent
group-*Section
group-*Header
group-*Content
```

**XML Project Patterns:**
```
Configuration=
PropertyGroup
ItemGroup
DependencyFramework
AdditionalDebugSymbols
```

### 3. Delphi Commit Message Patterns

**Category Prefixes (skia4delphi style):**
```
[Library] - Core library changes
[Tests] - Test modifications
[API] - API changes
[FMX Render] - FMX rendering
[VCL Render] - VCL rendering
[Controls] - UI controls
[Setup] - Installation/setup
[Documentation] - Docs
[Samples] - Sample code
```

**Version Patterns:**
```
Bump version to X.Y.Z
Update externals to mXXX
RAD Studio XX [Version Name]
Delphi XX [Version Name]
```

**Delphi Version Names:**
- RAD Studio 13 Florence
- RAD Studio 12 Athens
- RAD Studio 11 Alexandria
- Delphi 10.4 Sydney
- D10.1 Berlin
- XE7, XE8, etc.
- D7 (Delphi 7)

### 4. Delphi-Specific Areas

**UI Frameworks:**
- FMX (FireMonkey) - Cross-platform
- VCL - Windows-only

**Platform Targets:**
- Win32, Win64
- Android32, Android64 (armeabi-v7a, arm64-v8a)
- iOSDevice64, iOSSimARM64
- Linux64
- macOS (OSX64, OSXARM64)

**Build Systems:**
- MSBuild integration
- Component packages (.dpk, .bpl)
- GetIt package manager

---

## Recommended Improvements

### 1. Add to IGNORE_FILES
```python
# Delphi project files
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
```

### 2. Add to SPAM_PATTERNS
```python
# Delphi build variables
r'\$\(Platform\)',
r'\$\(BDS\w*\)',
r'\$\(Base_\w+\)',
r'\$\(ProjectName\)',
r'\$\(MSBuild\w+\)',
r'\$\(APPDATA\)\\Embarcadero',
# Delphi resource patterns
r'Android(Lib|File|Service|_)\w+',
r'iOS_\w+\d+',
r'iPad_\w+',
r'iPhone_\w+',
r'UWP_\w+',
# Delphi XML patterns
r'<PropertyGroup\s',
r'<ItemGroup\s',
r'Configuration=',
r'DependencyFramework',
# Help file patterns
r'collapsibleArea\w*',
r'contentEditableControl',
r'hiddenScrollOffset',
r'group-\w+Section',
r'group-\w+Header',
r'group-\w+Content',
```

### 3. Add Commit Prefix Patterns
```python
DELPHI_PREFIXES = {
    '[Library]': 'change',
    '[Tests]': 'other',
    '[API]': 'change',
    '[FMX Render]': 'enhancement',
    '[VCL Render]': 'enhancement',
    '[Controls]': 'enhancement',
    '[Setup]': 'other',
    '[Documentation]': 'other',
    '[Samples]': 'other',
}
```

### 4. Add Delphi Area Detection
```python
DELPHI_AREAS = {
    'FMX': ['fmx', 'firemonkey'],
    'VCL': ['vcl'],
    'RTL': ['rtl', 'system'],
    'Mobile': ['android', 'ios', 'mobile'],
    'Desktop': ['win32', 'win64', 'macos', 'linux'],
}
```

---

---

## Phase 2: CEF4Delphi and Graphics32 Analysis

### Additional Repositories Analyzed

| Repository | Focus | Commit Style |
|------------|-------|--------------|
| CEF4Delphi | Chromium Embedded Framework | `Update to CEF X.Y.Z` |
| graphics32 | 2D graphics library | Standard descriptive |

### New Patterns Identified

#### 1. Lazarus/FPC Patterns
```
lib/$(TargetCPU)-$(TargetOS)
-dUseCThreads
-dBorland -dVer150 -dDelphi7
LCLWidgetType
$(ProjOutDir)
```

#### 2. Lazarus Project Files
```
*.lpi - Lazarus project info
*.lps - Lazarus session
*.lpk - Lazarus package
*.compiled - Compilation marker
```

#### 3. Version Update Patterns
```
Update to CEF X.Y.Z -> dependency
Update to Chromium X.Y.Z -> dependency
Update to Skia mXXX -> dependency
```

### Results After Phase 2 Improvements

| Repository | Before | After | Reduction |
|------------|--------|-------|-----------|
| CEF4Delphi | 39 | 32 | 18% |
| graphics32 | 35 | 28 | 20% |

---

## Phase 3: xHarbour Analysis

### Repositories Analyzed

| Repository | Focus | Commit Style |
|------------|-------|--------------|
| xharbour | xHarbour compiler | `Description (#PR)` |
| sqlrddpp-v2 | SQL RDD for Harbour | `Update file: description` |
| harbour_and_xharbour_builds | Pre-built binaries | Build releases |

### xHarbour File Extensions

```
.prg  - Harbour/xHarbour source code
.ch   - Harbour header/include files
.hbp  - Harbour project file
.hbc  - Harbour build config
.hbm  - Harbour make file
.hbs  - Harbour script
.hrb  - Harbour portable executable
```

### xHarbour Noise Patterns Added

```python
r'Update ChangeLog'      # Auto-update commits
r'ChangeLog SVN version'
r'HB_\w+_\w+'           # Internal constants (HB_FINITE_DBL)
r'__GNUC__'             # Compiler flags
r'__clang__'
r'LONG_PTR'
r'ULONG_PTR'
r'MinGW'
r'xbuild\.\w+\.ini'     # Build configs
```

### xHarbour Commit Patterns

```
# PR references at end - now stripped
"Fixed wrong pp behaviour (#103)" -> "Fixed wrong pp behaviour"

# "Pacify" keyword now recognized as bugfix
"Pacify warnings" -> category: bugfix
```

### Results After Phase 3 Improvements

| Repository | Before | After | Improvement |
|------------|--------|-------|-------------|
| xharbour | 3 | 20 | **567%** |
| sqlrddpp-v2 | 19 | 19 | (already good) |

---

*Analysis completed: December 26, 2025*
*Repositories: 11 projects (6 Delphi + 2 Delphi + 3 xHarbour)*
