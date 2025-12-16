
# Python Version Manager by ehzawad@gmail.com
#
# WHAT THIS DOES:
# - Forces explicit Python versions (python3.X) - no default python/python3
# - Blocks pip outside virtual environments
# - Auto-detects venvs and exports VIRTUAL_ENV for subprocesses
# - Temporary version override with 'setpy <version>'
# - Build mode for pip access with 'setpy <version> --build'
#   (Build mode auto-clears in new shell sessions)
#
# LIMITATIONS (Fundamental OS restrictions):
# - Wrapper functions ONLY work in interactive shells where you type commands
# - Subprocesses/sandboxes inherit ENVIRONMENT VARIABLES but NOT shell functions
# - When Claude Code/Codex spawn subshells, they get exported vars (VIRTUAL_ENV, PATH)
#   but NOT the wrapper functions - this is normal Unix behavior
#
# SANDBOXED ENVIRONMENT SUPPORT:
# Auto-detects when helper functions aren't loaded and safely falls back to system commands.
# Bypass triggers: non-interactive shells, CI=1, CODEX_SANDBOX_NETWORK_DISABLED=1
# Manual bypass: export PYTHON_MANAGER_FORCE_BYPASS=1
# Diagnostics: Run 'pydiag'
#
# Global variables
typeset -ga _PYTHON_VERSIONS
typeset -gA _PYTHON_PATHS
typeset -gA _PYTHON_INFO
typeset -g _VENV_PYTHON_VERSION_CACHE=""
typeset -g _LAST_VIRTUAL_ENV=""
typeset -g _PYTHONS_SCANNED=0
typeset -g _PYTHON_OVERRIDE=""
typeset -gi _PYTHON_MANAGER_READY=0
typeset -g _PYTHON_BUILD_MODE=0
typeset -g _PYMANAGER_LAST_SET_BIN_DIR=""
typeset -g _PYMANAGER_LAST_WRAPPER_DIR=""
typeset -gi _PYMANAGER_SAVED_PIP_REQUIRE_VIRTUALENV_SET=0
typeset -g _PYMANAGER_SAVED_PIP_REQUIRE_VIRTUALENV=""

# === EARLY PATH SETUP (runs on source, before functions are defined) ===
# This ensures login shells get correct PATH even without full function loading.
# Idempotent: safe to source multiple times.
#
# IMPORTANT: We must run this setup if:
#   1. First time sourcing (_PYMANAGER_PATH_INIT not set), OR
#   2. VIRTUAL_ENV is set but its bin is NOT at the FRONT of PATH
#   3. CONDA_PREFIX is set but its bin is NOT at the FRONT of PATH
#
# This fixes the bug where Codex/cursor-agent spawn subshells that inherit
# _PYMANAGER_PATH_INIT but have wrong PATH ordering (venv bin after /usr/bin).
{
  local _pymanager_needs_path_fix=0

  # Check if we need to run the path setup
  if [[ -z "${_PYMANAGER_PATH_INIT:-}" ]]; then
    _pymanager_needs_path_fix=1
  elif [[ -n "${VIRTUAL_ENV:-}" ]] && [[ -d "$VIRTUAL_ENV/bin" ]]; then
    # VIRTUAL_ENV is set - check if its bin is at the FRONT of PATH (not just present)
    # This catches the case where subshells inherit _PYMANAGER_PATH_INIT but have
    # wrong PATH ordering (e.g., /usr/bin before venv bin)
    local _first_path="${PATH%%:*}"
    local _second_path=""
    local _rest="${PATH#*:}"
    [[ "$_rest" != "$PATH" ]] && _second_path="${_rest%%:*}"

    # Venv bin should be first, OR second if a pymanager wrapper is first
    if [[ "$_first_path" == "$VIRTUAL_ENV/bin" ]]; then
      : # OK - venv is first
    elif [[ "$_first_path" =~ ^/tmp/pymanager-[0-9]+/bin$ ]] && \
         [[ "$_second_path" == "$VIRTUAL_ENV/bin" ]]; then
      : # OK - pymanager wrapper first, venv second
    else
      _pymanager_needs_path_fix=1
    fi
  elif [[ -n "${CONDA_PREFIX:-}" ]] && [[ -d "$CONDA_PREFIX/bin" ]]; then
    # CONDA_PREFIX is set - same logic as VIRTUAL_ENV
    local _first_path="${PATH%%:*}"
    local _second_path=""
    local _rest="${PATH#*:}"
    [[ "$_rest" != "$PATH" ]] && _second_path="${_rest%%:*}"

    if [[ "$_first_path" == "$CONDA_PREFIX/bin" ]]; then
      : # OK - conda is first
    elif [[ "$_first_path" =~ ^/tmp/pymanager-[0-9]+/bin$ ]] && \
         [[ "$_second_path" == "$CONDA_PREFIX/bin" ]]; then
      : # OK - pymanager wrapper first, conda second
    else
      _pymanager_needs_path_fix=1
    fi
  fi

  if (( _pymanager_needs_path_fix )); then
    export _PYMANAGER_PATH_INIT=1
    
    # First, check if there's already a pymanager wrapper directory in PATH (from setpy in parent shell)
    # We need to preserve its position at the front
    local _pymanager_existing_wrapper=""
    local dir
    for dir in $path; do
      if [[ "$dir" =~ ^/tmp/pymanager-[0-9]+/bin$ ]]; then
        _pymanager_existing_wrapper="$dir"
        break
      fi
    done
    
    if [[ -n "${VIRTUAL_ENV:-}" ]] && [[ -d "$VIRTUAL_ENV/bin" ]]; then
      # Venv active - ensure venv's bin is first
      path=("$VIRTUAL_ENV/bin" ${path:#"$VIRTUAL_ENV/bin"})
    elif [[ -n "${CONDA_PREFIX:-}" ]] && [[ -d "$CONDA_PREFIX/bin" ]]; then
      # Conda active - ensure conda's bin is first
      path=("$CONDA_PREFIX/bin" ${path:#"$CONDA_PREFIX/bin"})
    elif [[ -d "$HOME/opt/python" ]]; then
      # No venv/conda - find latest Python in ~/opt/python/
      _pymanager_init_bin=$(find "$HOME/opt/python" -maxdepth 2 -type d -name bin 2>/dev/null | sort -t/ -k6 -V | tail -1)
      if [[ -n "$_pymanager_init_bin" ]] && [[ -d "$_pymanager_init_bin" ]]; then
        path=("$_pymanager_init_bin" ${path:#"$_pymanager_init_bin"})
      fi
      unset _pymanager_init_bin
    fi
    
    # ~/.local/bin always early (user scripts)
    if [[ -d "$HOME/.local/bin" ]]; then
      path=("$HOME/.local/bin" ${path:#"$HOME/.local/bin"})
    fi
    
    # If there was an existing pymanager wrapper, put it back at the very front
    # This preserves setpy's configuration when subshells are spawned
    if [[ -n "$_pymanager_existing_wrapper" ]] && [[ -d "$_pymanager_existing_wrapper" ]]; then
      path=("$_pymanager_existing_wrapper" ${path:#"$_pymanager_existing_wrapper"})
    fi
    unset _pymanager_existing_wrapper
    
    export PATH="${(j/:/)path}"
  fi
}

# Comprehensive Python scanner - lazy loaded
_scan_all_pythons() {
    # Skip if already scanned
    [[ $_PYTHONS_SCANNED -eq 1 ]] && return 0
    
    _PYTHON_VERSIONS=()
    _PYTHON_PATHS=()
    _PYTHON_INFO=()
    
    # All possible Python locations on macOS
    local search_paths=(
        # User installations (preferred)
        "$HOME/.local/bin"
        "$HOME/bin"
        "$HOME/.pythons/*/bin"
        "$HOME/Library/Python/*/bin"
        
        # Homebrew
        "/opt/homebrew/bin"
        "/opt/homebrew/opt/python@*/bin"
        "/usr/local/bin"
        "/usr/local/opt/python@*/bin"
        
        # System Python
        "/usr/bin"
        
        # Custom installations
        "/opt/python*/bin"
        "$HOME/opt/python*/bin"
        "$HOME/opt/python/*/bin"      # For structure like ~/opt/python/3.12.12/bin
        "/opt/python/*/bin"            # For structure like /opt/python/3.12.12/bin
    )
    
    # First pass: find all python executables
    local python_executables=()
    
    for pattern in "${search_paths[@]}"; do
        # Debug: show patterns being searched
        [[ -n "${PYMANAGER_DEBUG:-}" ]] && echo "[pymanager debug] Searching pattern: $pattern" >&2
        for dir in ${~pattern}(N/); do
            [[ -d "$dir" ]] || continue
            [[ -n "${PYMANAGER_DEBUG:-}" ]] && echo "[pymanager debug]   Found dir: $dir" >&2
            
            # Find ALL python executables
            for py in "$dir"/python*(N); do
                [[ -x "$py" ]] || continue
                [[ "$py" =~ "python-config" ]] && continue
                [[ "$py" =~ "pythonw" ]] && continue

                python_executables+=("$py")
            done
        done
    done
    
    # Second pass: get version info for each executable
    for py in "${python_executables[@]}"; do
        # Try to get version
        local version=""
        local fullver=""
        
        # Method 1: Extract from filename (require dot: python3.12, not python312)
        if [[ "${py:t}" =~ '^python([0-9]+\.[0-9]+)$' ]]; then
            version="${match[1]}"
        fi
        
        # Method 2: Run the executable to get version (with validation)
        if fullver=$("$py" --version 2>&1); then
            # Validate it's actually Python
            if [[ ! "$fullver" =~ ^Python ]]; then
                continue  # Not a Python interpreter
            fi
            if [[ "$fullver" =~ 'Python ([0-9]+)\.([0-9]+)\.?[0-9]*' ]]; then
                local extracted_version="${match[1]}.${match[2]}"

                if [[ -z "$version" ]]; then
                    version="$extracted_version"
                fi

                # Skip Python 2
                if [[ "${match[1]}" == "2" ]]; then
                    continue
                fi
            fi
        else
            # Debug: show which pythons fail to execute (only if PYMANAGER_DEBUG is set)
            [[ -n "${PYMANAGER_DEBUG:-}" ]] && echo "[pymanager debug] Failed to execute: $py ($fullver)" >&2
            continue
        fi
        
        # If we still don't have a version, try one more method
        if [[ -z "$version" ]] || [[ "$version" == "3" ]]; then
            local pyver=$("$py" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)
            if [[ -n "$pyver" ]] && [[ "$pyver" =~ '^3\.' ]]; then
                version="$pyver"
            fi
        fi
        
        # Skip if we couldn't determine version or if it's Python 2
        [[ -z "$version" ]] && continue
        [[ "$version" =~ '^2' ]] && continue
        
        # Get real path if it's a symlink (macOS-compatible)
        local realpath="$py"
        if [[ -L "$py" ]]; then
            local count=0
            while [[ -L "$realpath" ]] && (( count++ < 50 )); do
                local target=$(readlink "$realpath" 2>/dev/null || echo "$realpath")
                # Handle relative symlinks
                [[ "$target" != /* ]] && target="${realpath:h}/$target"
                realpath="$target"
            done
        fi
        
        # Determine if we should store this Python
        local should_store=0
        
        if [[ -z "${_PYTHON_PATHS[$version]}" ]]; then
            # First time seeing this major.minor version
            should_store=1
        else
            # Already have this version, decide which to keep
            
            # Preference 1: Always prefer $HOME/.local/bin
            if [[ "${py%/*}" == "$HOME/.local/bin" ]]; then
                should_store=1
            # Preference 2: Compare patch versions - keep the highest
            elif [[ "$fullver" =~ 'Python ([0-9]+)\.([0-9]+)\.([0-9]+)' ]]; then
                local new_major="${match[1]}"
                local new_minor="${match[2]}"
                local new_patch="${match[3]}"
                
                # Extract stored version
                local stored_info="${_PYTHON_INFO[$version]}"
                if [[ "$stored_info" =~ 'Python ([0-9]+)\.([0-9]+)\.([0-9]+)' ]]; then
                    local stored_major="${match[1]}"
                    local stored_minor="${match[2]}"
                    local stored_patch="${match[3]}"
                    
                    # Compare patch versions numerically
                    if (( new_patch > stored_patch )); then
                        should_store=1
                    fi
                fi
            fi
        fi
        
        # Store this Python if we decided to
        if [[ $should_store -eq 1 ]]; then
            # Only add to array if this is the first time we see this major.minor
            if [[ -z "${_PYTHON_PATHS[$version]}" ]]; then
                _PYTHON_VERSIONS+=("$version")
            fi
            _PYTHON_PATHS[$version]="$py"
            _PYTHON_INFO[$version]="$fullver ($realpath)"
        fi
    done
    
    # Sort versions properly (3.9 < 3.10 < 3.11...)
    _PYTHON_VERSIONS=(${(u)_PYTHON_VERSIONS})
    _PYTHON_VERSIONS=($(print -l "${_PYTHON_VERSIONS[@]}" | sort -t. -k1,1n -k2,2n))
    _PYTHONS_SCANNED=1
}

# Check if we're in a virtual environment
_in_virtual_env() {
    # Standard venv/virtualenv
    [[ -n "$VIRTUAL_ENV" ]] && return 0

    # Conda
    [[ -n "$CONDA_PREFIX" ]] && return 0
    [[ -n "$CONDA_DEFAULT_ENV" ]] && return 0

    # Poetry
    [[ -n "$POETRY_ACTIVE" ]] && return 0

    # Pipenv
    [[ -n "$PIPENV_ACTIVE" ]] && return 0

    # Heuristic: Check if python command points to a venv-like structure
    # This helps detect venvs created by sandboxed environments
    # Use whence -p to get actual binary path (command -v returns function name if defined)
    local python_path=$(whence -p python 2>/dev/null)
    if [[ -n "$python_path" ]] && [[ -x "$python_path" ]]; then
        # Check if python is in a bin/ directory with activate script
        if [[ "$python_path" =~ /bin/python ]]; then
            local venv_dir="${python_path%/bin/python*}"
            # Validate this looks like a venv (has activate script and pyvenv.cfg)
            if [[ -f "$venv_dir/bin/activate" ]] && [[ -f "$venv_dir/pyvenv.cfg" ]]; then
                # Temporarily set VIRTUAL_ENV if not already set
                # This helps the rest of the script work correctly
                if [[ -z "$VIRTUAL_ENV" ]]; then
                    export VIRTUAL_ENV="$venv_dir"
                fi
                return 0
            fi
        fi
    fi

    return 1
}

# Get the active environment's bin directory (venv or conda), if any.
_py_manager_env_bin_dir() {
    if [[ -n "${VIRTUAL_ENV:-}" ]] && [[ -d "$VIRTUAL_ENV/bin" ]]; then
        echo "$VIRTUAL_ENV/bin"
        return 0
    fi
    if [[ -n "${CONDA_PREFIX:-}" ]] && [[ -d "$CONDA_PREFIX/bin" ]]; then
        echo "$CONDA_PREFIX/bin"
        return 0
    fi
    return 1
}

_py_manager_file_size() {
    local target="$1"
    local size=""

    size=$(command stat -f%z "$target" 2>/dev/null) || true
    if [[ -z "$size" ]]; then
        size=$(command stat -c%s "$target" 2>/dev/null) || true
    fi

    [[ "$size" == <-> ]] || size=0
    echo "$size"
}

# Get the Python version used by current venv - with caching
_get_venv_python_version() {
    # Check cache first
    if [[ -n "$VIRTUAL_ENV" ]] && [[ "$VIRTUAL_ENV" == "$_LAST_VIRTUAL_ENV" ]] && [[ -n "$_VENV_PYTHON_VERSION_CACHE" ]]; then
        echo "$_VENV_PYTHON_VERSION_CACHE"
        return 0
    fi
    
    local ver=""
    
    if [[ -n "$VIRTUAL_ENV" ]]; then
        # Method 1: Check pyvenv.cfg (fastest)
        if [[ -f "$VIRTUAL_ENV/pyvenv.cfg" ]]; then
            # Extract only major.minor version (3.12) not full version (3.12.11)
            local full_version=$(grep -E "^version\s*=" "$VIRTUAL_ENV/pyvenv.cfg" 2>/dev/null | sed -E 's/^version\s*=\s*(.*)$/\1/' | tr -d ' ')
            if [[ "$full_version" =~ ^([0-9]+\.[0-9]+) ]]; then
                ver="${match[1]}"
            fi
        fi
        
        # Method 2: Run the venv's python (slower but reliable)
        if [[ -z "$ver" ]] && [[ -x "$VIRTUAL_ENV/bin/python" ]]; then
            ver=$("$VIRTUAL_ENV/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)
        fi
        
        # Cache the result
        if [[ -n "$ver" ]]; then
            _LAST_VIRTUAL_ENV="$VIRTUAL_ENV"
            _VENV_PYTHON_VERSION_CACHE="$ver"
            echo "$ver"
            return 0
        fi
    fi
    
    # For conda
    if [[ -n "${CONDA_PREFIX:-}" ]] && [[ -x "$CONDA_PREFIX/bin/python" ]]; then
        ver=$("$CONDA_PREFIX/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)
        if [[ -n "$ver" ]]; then
            echo "$ver"
            return 0
        fi
    elif [[ -n "$CONDA_DEFAULT_ENV" ]] && command -v python >/dev/null 2>&1; then
        ver=$(command python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)
        if [[ -n "$ver" ]]; then
            echo "$ver"
            return 0
        fi
    fi
    
    return 1
}

# Fast venv version check - doesn't run python, just reads pyvenv.cfg
# Used in bypass mode where we need quick version checks
_get_venv_version_fast() {
    if [[ -n "${VIRTUAL_ENV:-}" ]] && [[ -f "$VIRTUAL_ENV/pyvenv.cfg" ]]; then
        local full_ver=$(grep -E "^version\s*=" "$VIRTUAL_ENV/pyvenv.cfg" 2>/dev/null | sed 's/.*=\s*//' | tr -d ' ')
        if [[ "$full_ver" =~ ^([0-9]+\.[0-9]+) ]]; then
            echo "${match[1]}"
            return 0
        fi
    fi
    return 1
}

# Determine if the manager internals are ready (handles partial loads)
_py_manager_available() {
    [[ ${_PYTHON_MANAGER_READY:-0} -eq 1 ]] || return 1
    typeset -f _in_virtual_env >/dev/null 2>&1 || return 1
    typeset -f _scan_all_pythons >/dev/null 2>&1 || return 1
    return 0
}

# Detect automation contexts where we should not intercept python calls
_py_manager_should_bypass() {
    # Explicit bypass flag
    [[ -n "${PYTHON_MANAGER_FORCE_BYPASS:-}" ]] && return 0

    # CI environments
    [[ -n "${CI:-}" ]] && return 0

    # Non-interactive shells (scripts, subshells, sandboxed execution)
    [[ ! -o interactive ]] && return 0

    # Codex sandbox detection (confirmed real env var)
    [[ -n "${CODEX_SANDBOX_NETWORK_DISABLED:-}" ]] && return 0

    return 1
}

# Python wrapper
python() {
    # CRITICAL: Check if helper functions exist (for sandboxed environments)
    if ! typeset -f _py_manager_should_bypass >/dev/null 2>&1 || \
       ! typeset -f _py_manager_available >/dev/null 2>&1; then
        # Functions not loaded, just use system python
        command python "$@"
        return $?
    fi

    if _py_manager_should_bypass; then
        command python "$@"
        local _py_status=$?
        if (( _py_status == 127 || _py_status == 126 )) && _py_manager_available; then
            _scan_all_pythons
            if (( ${#_PYTHON_VERSIONS} )); then
                local fallback_version="${_PYTHON_VERSIONS[-1]}"
                "${_PYTHON_PATHS[$fallback_version]}" "$@"
                return $?
            fi
        fi
        return $_py_status
    fi

    if ! _py_manager_available; then
        command python "$@"
        return $?
    fi

    # Priority 1: Virtual environment
    if _in_virtual_env; then
        local env_bin_dir=$(_py_manager_env_bin_dir 2>/dev/null)
        if [[ -n "$env_bin_dir" ]] && [[ -x "$env_bin_dir/python" ]]; then
            "$env_bin_dir/python" "$@"
        else
            command python "$@"
        fi
        return $?
    fi
    
    # Priority 2: Temporary override
    if [[ -n "$_PYTHON_OVERRIDE" ]]; then
        # Validate override still exists
        if ! _validate_python_override; then
            return 1
        fi

        # Check if trying to use pip module (blocked unless build mode)
        if [[ "$#" -ge 2 ]] && [[ "$1" == "-m" ]] && [[ "$2" == "pip" ]]; then
            if [[ $_PYTHON_BUILD_MODE -eq 1 ]]; then
                # Build mode: allow python -m pip
                _scan_all_pythons
                if [[ -n "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" ]]; then
                    echo "[build mode] Running python -m pip with Python ${_PYTHON_OVERRIDE}..." >&2
                    "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" "$@"
                    return $?
                fi
            else
                echo "Error: python -m pip is blocked outside virtual environments"
                echo ""
                echo "To use pip:"
                echo "   1. Create a virtual environment: python${_PYTHON_OVERRIDE} -m venv [venv-projname]"
                echo "   2. Activate it: source [venv-projname]/bin/activate"
                echo "   3. Then use pip normally"
                echo ""
                echo "This prevents accidental system-wide package installations."
                echo "Tip: Use 'setpy ${_PYTHON_OVERRIDE} --build' to temporarily allow pip."
                return 1
            fi
        fi

        # _validate_python_override already scanned, path guaranteed to exist
        "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" "$@"
        return $?
    fi
    
    # Default: Show error
    _scan_all_pythons

    echo "Error: No default 'python' command available"
    echo ""

    if (( ${#_PYTHON_VERSIONS} == 0 )); then
        echo "Warning: No Python 3.x installations found!"
        return 1
    fi

    echo "Available Python versions:"
    echo ""

    local sorted_versions=($(print -l "${_PYTHON_VERSIONS[@]}" | sort -t. -k1,1n -k2,2n -r))
    for ver in $sorted_versions; do
        echo "  - python${ver} -> ${_PYTHON_INFO[$ver]}"
    done

    echo ""
    echo "Options:"
    echo "   1. Create venv: python${_PYTHON_VERSIONS[-1]} -m venv [venv-projname] && source [venv-projname]/bin/activate"
    echo "   2. Set temporary default: setpy ${_PYTHON_VERSIONS[-1]}"

    return 1
}

# Python3 wrapper
python3() {
    # CRITICAL: Check if helper functions exist (for sandboxed environments)
    if ! typeset -f _py_manager_should_bypass >/dev/null 2>&1 || \
       ! typeset -f _py_manager_available >/dev/null 2>&1; then
        # Functions not loaded, just use system python3
        command python3 "$@"
        return $?
    fi

    if _py_manager_should_bypass; then
        command python3 "$@"
        local _py_status=$?
        if (( _py_status == 127 || _py_status == 126 )) && _py_manager_available; then
            _scan_all_pythons
            if (( ${#_PYTHON_VERSIONS} )); then
                local fallback_version="${_PYTHON_VERSIONS[-1]}"
                "${_PYTHON_PATHS[$fallback_version]}" "$@"
                return $?
            fi
        fi
        return $_py_status
    fi

    if ! _py_manager_available; then
        command python3 "$@"
        return $?
    fi

    # Priority 1: Virtual environment
    if _in_virtual_env; then
        local env_bin_dir=$(_py_manager_env_bin_dir 2>/dev/null)
        if [[ -n "$env_bin_dir" ]] && [[ -x "$env_bin_dir/python3" ]]; then
            "$env_bin_dir/python3" "$@"
        else
            command python3 "$@"
        fi
        return $?
    fi
    
    # Priority 2: Temporary override
    if [[ -n "$_PYTHON_OVERRIDE" ]]; then
        # Validate override still exists
        if ! _validate_python_override; then
            return 1
        fi

        # Check if trying to use pip module (blocked unless build mode)
        if [[ "$#" -ge 2 ]] && [[ "$1" == "-m" ]] && [[ "$2" == "pip" ]]; then
            if [[ $_PYTHON_BUILD_MODE -eq 1 ]]; then
                # Build mode: allow python3 -m pip
                _scan_all_pythons
                if [[ -n "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" ]]; then
                    echo "[build mode] Running python3 -m pip with Python ${_PYTHON_OVERRIDE}..." >&2
                    "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" "$@"
                    return $?
                fi
            else
                echo "Error: python3 -m pip is blocked outside virtual environments"
                echo ""
                echo "To use pip:"
                echo "   1. Create a virtual environment: python${_PYTHON_OVERRIDE} -m venv [venv-projname]"
                echo "   2. Activate it: source [venv-projname]/bin/activate"
                echo "   3. Then use pip normally"
                echo ""
                echo "This prevents accidental system-wide package installations."
                echo "Tip: Use 'setpy ${_PYTHON_OVERRIDE} --build' to temporarily allow pip."
                return 1
            fi
        fi

        # _validate_python_override already scanned, path guaranteed to exist
        "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" "$@"
        return $?
    fi
    
    # Default: Show error
    _scan_all_pythons

    echo "Error: No default 'python3' command available"
    echo ""

    if (( ${#_PYTHON_VERSIONS} == 0 )); then
        echo "Warning: No Python 3.x installations found!"
        return 1
    fi

    echo "Available Python versions:"
    echo ""

    local sorted_versions=($(print -l "${_PYTHON_VERSIONS[@]}" | sort -t. -k1,1n -k2,2n -r))
    for ver in $sorted_versions; do
        echo "  - python${ver} -> ${_PYTHON_INFO[$ver]}"
    done

    echo ""
    echo "Options:"
    echo "   1. Create venv: python${_PYTHON_VERSIONS[-1]} -m venv [venv-projname] && source [venv-projname]/bin/activate"
    echo "   2. Set temporary default: setpy ${_PYTHON_VERSIONS[-1]}"

    return 1
}

# Pip wrapper - allows override only in build mode
pip() {
    # CRITICAL: Check if helper functions exist (for sandboxed environments)
    if ! typeset -f _py_manager_should_bypass >/dev/null 2>&1 || \
       ! typeset -f _py_manager_available >/dev/null 2>&1 || \
       ! typeset -f _in_virtual_env >/dev/null 2>&1; then
        # Functions not loaded, just use system pip
        command pip "$@"
        return $?
    fi

    if _py_manager_should_bypass; then
        command pip "$@"
        return $?
    fi

    if ! _py_manager_available; then
        command pip "$@"
        return $?
    fi

    if _in_virtual_env; then
        local env_bin_dir=$(_py_manager_env_bin_dir 2>/dev/null)
        if [[ -n "$env_bin_dir" ]] && [[ -x "$env_bin_dir/pip" ]]; then
            "$env_bin_dir/pip" "$@"
        else
            command pip "$@"
        fi
        return $?
    fi

    # Build mode: allow pip with the override Python
    if [[ $_PYTHON_BUILD_MODE -eq 1 ]] && [[ -n "$_PYTHON_OVERRIDE" ]]; then
        _scan_all_pythons
        local python_path="${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}"
        if [[ -n "$python_path" ]]; then
            echo "[build mode] Running pip with Python ${_PYTHON_OVERRIDE}..." >&2
            "$python_path" -m pip "$@"
            return $?
        fi
    fi

    echo "Error: pip is not available outside virtual environments"
    echo ""
    echo "To use pip:"
    echo "   1. Create a virtual environment: python3.x -m venv [venv-projname]"
    echo "   2. Activate it: source [venv-projname]/bin/activate"
    echo "   3. Then use pip normally"
    echo ""
    echo "This prevents accidental system-wide package installations."
    if [[ -n "$_PYTHON_OVERRIDE" ]]; then
        echo ""
        echo "Tip: Use 'setpy ${_PYTHON_OVERRIDE} --build' to temporarily allow pip."
    fi

    return 1
}

# Pip3 wrapper - allows override only in build mode
pip3() {
    # CRITICAL: Check if helper functions exist (for sandboxed environments)
    if ! typeset -f _py_manager_should_bypass >/dev/null 2>&1 || \
       ! typeset -f _py_manager_available >/dev/null 2>&1 || \
       ! typeset -f _in_virtual_env >/dev/null 2>&1; then
        command pip3 "$@"
        return $?
    fi

    if _py_manager_should_bypass; then
        command pip3 "$@"
        return $?
    fi

    if ! _py_manager_available; then
        command pip3 "$@"
        return $?
    fi

    if _in_virtual_env; then
        local env_bin_dir=$(_py_manager_env_bin_dir 2>/dev/null)
        if [[ -n "$env_bin_dir" ]] && [[ -x "$env_bin_dir/pip3" ]]; then
            "$env_bin_dir/pip3" "$@"
        else
            command pip3 "$@"
        fi
        return $?
    fi

    # Build mode: allow pip3 with the override Python
    if [[ $_PYTHON_BUILD_MODE -eq 1 ]] && [[ -n "$_PYTHON_OVERRIDE" ]]; then
        _scan_all_pythons
        local python_path="${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}"
        if [[ -n "$python_path" ]]; then
            echo "[build mode] Running pip3 with Python ${_PYTHON_OVERRIDE}..." >&2
            "$python_path" -m pip "$@"
            return $?
        fi
    fi

    echo "Error: pip3 is not available outside virtual environments"
    echo ""
    echo "To use pip:"
    echo "   1. Create a virtual environment: python3.x -m venv [venv-projname]"
    echo "   2. Activate it: source [venv-projname]/bin/activate"
    echo "   3. Then use pip normally"
    echo ""
    echo "This prevents accidental system-wide package installations."
    if [[ -n "$_PYTHON_OVERRIDE" ]]; then
        echo ""
        echo "Tip: Use 'setpy ${_PYTHON_OVERRIDE} --build' to temporarily allow pip."
    fi

    return 1
}

# Set temporary Python default with AI tool support
setpy() {
    if ! _py_manager_available; then
        echo "Warning: Python manager helpers unavailable; cannot change override"
        return 1
    fi

    local version=""
    local build_mode=0
    local quiet=0

    [[ -n "${PYMANAGER_QUIET:-}" ]] && quiet=1

    # Parse arguments
    for arg in "$@"; do
        case "$arg" in
            -h|--help)
                _scan_all_pythons
                local example_ver="${_PYTHON_VERSIONS[-1]:-3.x}"
                echo "Usage: setpy <version> [--build]    Set temporary Python default"
                echo "       setpy clear                  Clear the override"
                echo "       setpy                        Show current status"
                echo ""
                echo "Options:"
                echo "   --build    Also allow pip outside venv (for building modules)"
                echo ""
                echo "Examples:"
                echo "   setpy ${example_ver}             # Set python/python3 to use Python ${example_ver}"
                echo "   setpy ${example_ver} --build     # Same, but also allow pip (for builds)"
                echo "   setpy python${example_ver}       # Also accepts 'python' prefix"
                echo "   setpy clear            # Remove the override and build mode"
                echo ""
                echo "Available versions:"
                for ver in $_PYTHON_VERSIONS; do
                    echo "   ${ver}"
                done
                echo ""
                echo "This sets a temporary default so 'python' and 'python3' work without a venv."
                echo "Exports PYTHON/PYTHON3 env vars for AI tool compatibility (no symlinks)."
                echo ""
                echo "Build mode (--build):"
                echo "   Temporarily allows pip/pip3 outside virtual environments."
                echo "   Use for building modules that require pip install."
                echo "   WARNING: Can pollute system packages - use sparingly!"
                echo "   Auto-clears in new shell sessions."
                return 0
                ;;
            --build)
                build_mode=1
                ;;
            --quiet|--silent)
                quiet=1
                ;;
            clear|reset)
                version="clear"
                ;;
            latest|auto)
                # Pick the newest installed Python version automatically
                if [[ -z "$version" ]]; then
                    version="latest"
                fi
                ;;
            *)
                # It's a version number
                if [[ -z "$version" ]]; then
                    version="$arg"
                fi
                ;;
        esac
    done

    # Handle clear/reset
    if [[ "$version" == "clear" ]]; then
        local had_override=0
        local had_build_mode=0

        [[ -n "$_PYTHON_OVERRIDE" ]] && had_override=1
        [[ $_PYTHON_BUILD_MODE -eq 1 ]] && had_build_mode=1

        if [[ $had_override -eq 1 ]] || [[ $had_build_mode -eq 1 ]]; then
            if [[ $had_override -eq 1 ]]; then
                (( quiet )) || echo "Cleared Python override (was ${_PYTHON_OVERRIDE})."
                _PYTHON_OVERRIDE=""
                unset PYTHON PYTHON3

                # Clean up temp wrapper directory
                if [[ -n "$_PYMANAGER_LAST_WRAPPER_DIR" ]] && [[ -d "$_PYMANAGER_LAST_WRAPPER_DIR" ]]; then
                    rm -rf "$_PYMANAGER_LAST_WRAPPER_DIR" 2>/dev/null
                    # Remove from PATH
                    if [[ -n "${ZSH_VERSION:-}" ]]; then
                        path=(${path:#"$_PYMANAGER_LAST_WRAPPER_DIR/bin"})
                        export PATH="${(j/:/)path}"
                    fi
                    _PYMANAGER_LAST_WRAPPER_DIR=""
                fi
            fi

            if [[ $had_build_mode -eq 1 ]]; then
                (( quiet )) || echo "Cleared build mode (pip is now blocked outside venvs)."
                _PYTHON_BUILD_MODE=0
                if (( _PYMANAGER_SAVED_PIP_REQUIRE_VIRTUALENV_SET )); then
                    export PIP_REQUIRE_VIRTUALENV="$_PYMANAGER_SAVED_PIP_REQUIRE_VIRTUALENV"
                else
                    unset PIP_REQUIRE_VIRTUALENV
                fi
                _PYMANAGER_SAVED_PIP_REQUIRE_VIRTUALENV_SET=0
                _PYMANAGER_SAVED_PIP_REQUIRE_VIRTUALENV=""
                unset PYMANAGER_BUILD_MODE PYMANAGER_SAVED_PIP_REQUIRE_VIRTUALENV_SET PYMANAGER_SAVED_PIP_REQUIRE_VIRTUALENV
            fi
        else
            (( quiet )) || echo "No Python override or build mode is set."
        fi
        return 0
    fi

    # No argument - show status and available versions
    if [[ -z "$version" ]]; then
        _scan_all_pythons
        if [[ -n "$_PYTHON_OVERRIDE" ]] || [[ $_PYTHON_BUILD_MODE -eq 1 ]]; then
            if [[ -n "$_PYTHON_OVERRIDE" ]]; then
                echo "Current override: Python ${_PYTHON_OVERRIDE}"
                echo "   Binary: ${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}"
            fi
            if [[ $_PYTHON_BUILD_MODE -eq 1 ]]; then
                echo "Build mode: ENABLED (pip allowed outside venv)"
            fi
            echo ""
            echo "To clear: setpy clear"
        else
            echo "No Python override is set."
            echo ""
            echo "Usage: setpy <version> [--build]"
            echo ""
            echo "Available versions:"
            for ver in $_PYTHON_VERSIONS; do
                echo "   setpy ${ver}"
            done
            echo ""
            echo "Run 'setpy --help' for more info."
        fi
        return 0
    fi

    # Strip "python" prefix if provided (accept both "3.12" and "python3.12")
    if [[ "$version" =~ ^python([0-9]+\.[0-9]+)$ ]]; then
        version="${match[1]}"
    elif [[ "$version" =~ ^py([0-9]+\.[0-9]+)$ ]]; then
        version="${match[1]}"
    fi

    # Force re-scan to get fresh paths (avoid stale symlinks)
    _PYTHONS_SCANNED=0
    _scan_all_pythons

    # Resolve "latest"/"auto" to the newest available version
    if [[ "$version" == "latest" ]]; then
        if (( ${#_PYTHON_VERSIONS} == 0 )); then
            echo "Error: No Python 3.x installations found on this system"
            return 1
        fi
        version="${_PYTHON_VERSIONS[-1]}"
    fi

    # Validate version exists
    if [[ -z "${_PYTHON_PATHS[$version]}" ]]; then
        echo "Error: Python ${version} not found on this system"
        echo ""
        echo "Available versions:"
        for ver in $_PYTHON_VERSIONS; do
            echo "  - ${ver}"
        done
        return 1
    fi

    local python_path="${_PYTHON_PATHS[$version]}"

    # Prefer a real interpreter path for exports/symlinks (avoid self-referential symlink loops)
    local python_target="$python_path"
    if [[ -L "$python_target" ]]; then
        local count=0
        while [[ -L "$python_target" ]] && (( count++ < 50 )); do
            local target
            target=$(readlink "$python_target" 2>/dev/null) || break
            [[ "$target" != /* ]] && target="${python_target:h}/$target"
            python_target="$target"
        done
    fi

    # If the stored path resolves to something non-executable (or a broken loop), fall back to pythonX.Y.
    local stored_bin_dir="${python_path%/*}"
    if [[ ! -x "$python_target" ]] && [[ -x "$stored_bin_dir/python${version}" ]]; then
        python_target="$stored_bin_dir/python${version}"
    fi

    # SAFETY CHECK: Verify the binary is functional (not empty/corrupt)
    local file_size=$(_py_manager_file_size "$python_target")
    if [[ "$file_size" -eq 0 ]]; then
        echo "Error: Python binary at $python_target is empty (0 bytes)!"
        echo ""
        echo "The file exists but appears to be corrupted."
        echo "Please reinstall Python ${version}."
        return 1
    fi

    # Verify it actually executes
    local test_output
    if ! test_output=$("$python_target" --version 2>&1); then
        echo "Error: Python binary at $python_target failed to execute!"
        echo ""
        echo "Output: $test_output"
        echo ""
        echo "Please reinstall Python ${version}."
        return 1
    fi

    # Set shell override
    _PYTHON_OVERRIDE="$version"

    # Get the bin directory for this Python
    local python_bin_dir="${python_target%/*}"

    # Export for subprocesses (AI tools like Claude Code, Codex)
    export PYTHON="$python_target"
    export PYTHON3="$python_target"

    # Create session-scoped temp wrapper scripts for subprocess compatibility
    # This makes python/python3 available to subprocesses (Claude Code, Codex, etc.)
    # without creating persistent symlinks
    local wrapper_dir="/tmp/pymanager-$$"
    mkdir -p "$wrapper_dir/bin" 2>/dev/null

    # Create python wrapper
    cat > "$wrapper_dir/bin/python" <<WRAPPER
#!/bin/sh
exec "$python_target" "\$@"
WRAPPER
    chmod +x "$wrapper_dir/bin/python"

    # Create python3 wrapper
    cat > "$wrapper_dir/bin/python3" <<WRAPPER
#!/bin/sh
exec "$python_target" "\$@"
WRAPPER
    chmod +x "$wrapper_dir/bin/python3"

    # Also link the versioned python (e.g., python3.14)
    ln -sf "$python_target" "$wrapper_dir/bin/python${version}" 2>/dev/null

    # Update PATH: wrapper_dir first, then python_bin_dir (for pip3.X etc), then rest
    # Keep active virtualenv/conda bins ahead of everything.
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        local active_env_bin=""
        if [[ -n "${VIRTUAL_ENV:-}" ]] && [[ -d "$VIRTUAL_ENV/bin" ]]; then
            active_env_bin="$VIRTUAL_ENV/bin"
        elif [[ -n "${CONDA_PREFIX:-}" ]] && [[ -d "$CONDA_PREFIX/bin" ]]; then
            active_env_bin="$CONDA_PREFIX/bin"
        fi

        local -a cleaned_path=()
        local previous_wrapper_dir="${_PYMANAGER_LAST_WRAPPER_DIR:-}"
        local previous_bin_dir="${_PYMANAGER_LAST_SET_BIN_DIR:-}"
        local dir
        for dir in $path; do
            [[ "$dir" == "$wrapper_dir/bin" ]] && continue
            [[ "$dir" == "$python_bin_dir" ]] && continue
            [[ -n "$previous_wrapper_dir" ]] && [[ "$dir" == "$previous_wrapper_dir/bin" ]] && continue
            [[ -n "$previous_bin_dir" ]] && [[ "$dir" == "$previous_bin_dir" ]] && continue
            cleaned_path+=("$dir")
        done

        if [[ -n "$active_env_bin" ]] && (( ${cleaned_path[(I)$active_env_bin]} )); then
            local -a new_path=()
            local inserted=0
            for dir in $cleaned_path; do
                new_path+=("$dir")
                if (( inserted == 0 )) && [[ "$dir" == "$active_env_bin" ]]; then
                    new_path+=("$wrapper_dir/bin" "$python_bin_dir")
                    inserted=1
                fi
            done
            if (( inserted == 0 )); then
                new_path=("$wrapper_dir/bin" "$python_bin_dir" $cleaned_path)
            fi
            path=($new_path)
        else
            path=("$wrapper_dir/bin" "$python_bin_dir" $cleaned_path)
        fi
        export PATH="${(j/:/)path}"
        _PYMANAGER_LAST_WRAPPER_DIR="$wrapper_dir"
        _PYMANAGER_LAST_SET_BIN_DIR="$python_bin_dir"
    else
        # Fallback for non-zsh
        local cleaned_path="$PATH"
        cleaned_path="${cleaned_path//:$wrapper_dir\/bin:/:}"
        cleaned_path="${cleaned_path/#$wrapper_dir\/bin:/}"
        cleaned_path="${cleaned_path/%:$wrapper_dir\/bin/}"
        cleaned_path="${cleaned_path//:$python_bin_dir:/:}"
        cleaned_path="${cleaned_path/#$python_bin_dir:/}"
        cleaned_path="${cleaned_path/%:$python_bin_dir/}"
        export PATH="$wrapper_dir/bin:$python_bin_dir:$cleaned_path"
    fi

    # Handle build mode
    if [[ $build_mode -eq 1 ]]; then
        if [[ $_PYTHON_BUILD_MODE -ne 1 ]]; then
            _PYMANAGER_SAVED_PIP_REQUIRE_VIRTUALENV_SET=${+PIP_REQUIRE_VIRTUALENV}
            _PYMANAGER_SAVED_PIP_REQUIRE_VIRTUALENV="${PIP_REQUIRE_VIRTUALENV-}"
            export PYMANAGER_SAVED_PIP_REQUIRE_VIRTUALENV_SET="$_PYMANAGER_SAVED_PIP_REQUIRE_VIRTUALENV_SET"
            export PYMANAGER_SAVED_PIP_REQUIRE_VIRTUALENV="$_PYMANAGER_SAVED_PIP_REQUIRE_VIRTUALENV"
            export PYMANAGER_BUILD_MODE=1
        fi
        _PYTHON_BUILD_MODE=1
        # This env var tells pip it's okay to run outside venv (for subprocesses)
        export PIP_REQUIRE_VIRTUALENV=0
    fi
    if (( ! quiet )); then
        echo "Set Python ${version} for this session."
        echo ""
        echo "Binary: $python_target"
        echo "Wrappers: $wrapper_dir/bin/"
        echo ""
        echo "Subprocesses (Claude Code, Codex, etc.) will find:"
        echo "   python, python3, python${version} → $python_target"

        if [[ $_PYTHON_BUILD_MODE -eq 1 ]]; then
            echo ""
            echo "┌─────────────────────────────────────────────────────────────┐"
            echo "│  BUILD MODE ENABLED - pip/pip3 allowed outside venv        │"
            echo "│  WARNING: This can install packages system-wide!           │"
            echo "│  Run 'setpy clear' when done building.                     │"
            echo "└─────────────────────────────────────────────────────────────┘"
        else
            echo ""
            echo "Note: pip remains blocked outside venvs. Use --build to allow."
        fi
        echo ""
        echo "To clear: setpy clear"

        # Warn if in venv
        if _in_virtual_env; then
            echo ""
            echo "Warning: You're in a virtual environment, which takes precedence."
        fi
    fi
}

# Validate that the override Python still exists
_validate_python_override() {
    if [[ -z "$_PYTHON_OVERRIDE" ]]; then
        return 0  # No override set
    fi

    # Re-scan to get current state
    _PYTHONS_SCANNED=0
    _scan_all_pythons

    local override_path="${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}"

    if [[ -z "$override_path" ]] || [[ ! -x "$override_path" ]]; then
        echo "Error: Python ${_PYTHON_OVERRIDE} is no longer available."
        echo ""
        echo "The previously set version may have been uninstalled."
        echo ""

        if (( ${#_PYTHON_VERSIONS} > 0 )); then
            echo "Available Python versions:"
            for ver in $_PYTHON_VERSIONS; do
                echo "  - ${ver} -> ${_PYTHON_PATHS[$ver]}"
            done
            echo ""
            echo "To fix:"
            echo "  1. setpy clear     (remove stale override)"
            echo "  2. setpy <version> (set a new version)"
        else
            echo "No Python installations found."
            echo "Run: setpy clear"
        fi

        return 1
    fi

    return 0
}

# Python version-specific wrapper function
_python_version_wrapper() {
    local version="$1"
    shift

    # CRITICAL: Check if helper functions exist (for sandboxed environments)
    if ! typeset -f _py_manager_should_bypass >/dev/null 2>&1 || \
       ! typeset -f _py_manager_available >/dev/null 2>&1; then
        # Functions not loaded, just use system python
        command "python${version}" "$@"
        return $?
    fi

    if _py_manager_should_bypass; then
        # VENV ENFORCEMENT: Even in bypass mode, block pip with mismatched version
        if [[ -n "${VIRTUAL_ENV:-}" ]] && [[ -d "$VIRTUAL_ENV/bin" ]]; then
            if [[ "$#" -ge 2 ]] && [[ "$1" == "-m" ]] && [[ "$2" == "pip" ]]; then
                local venv_ver=$(_get_venv_version_fast)
                if [[ -n "$venv_ver" ]] && [[ "$version" != "$venv_ver" ]]; then
                    echo "Error: python${version} -m pip blocked - venv uses Python ${venv_ver}" >&2
                    echo "" >&2
                    echo "This would install to system Python ${version}, not your venv." >&2
                    echo "Use 'python -m pip' or 'pip' instead." >&2
                    return 1
                fi
                # Version matches - use venv's python to ensure correct sys.prefix
                if [[ -x "$VIRTUAL_ENV/bin/python" ]]; then
                    "$VIRTUAL_ENV/bin/python" "$@"
                    return $?
                fi
            fi
        fi

        # Original bypass logic for non-pip operations
        if _py_manager_available; then
            _scan_all_pythons
            if [[ -n "${_PYTHON_PATHS[$version]}" ]]; then
                "${_PYTHON_PATHS[$version]}" "$@"
                return $?
            fi
        fi
        command "python${version}" "$@"
        return $?
    fi

    if ! _py_manager_available; then
        command "python${version}" "$@"
        return $?
    fi

    # If in venv, be more permissive
    if _in_virtual_env; then
        local env_bin_dir=$(_py_manager_env_bin_dir 2>/dev/null)

        # First, check if the requested python executable exists in the active env
        if [[ -n "$env_bin_dir" ]] && [[ -x "$env_bin_dir/python${version}" ]]; then
            # It exists! Just use it directly
            "$env_bin_dir/python${version}" "$@"
            return $?
        fi
        
        # If not found, check if this matches the venv's major.minor version
        local venv_version=$(_get_venv_python_version)
        
        # Extract just major.minor from the full version if needed
        if [[ "$venv_version" =~ ^([0-9]+\.[0-9]+) ]]; then
            venv_version="${match[1]}"
        fi
        
        if [[ -n "$venv_version" ]] && [[ "$version" == "$venv_version" ]]; then
            # Fall back to the env's python
            if [[ -n "$env_bin_dir" ]] && [[ -x "$env_bin_dir/python" ]]; then
                "$env_bin_dir/python" "$@"
                return $?
            fi
            command python "$@"
            return $?
        fi

        # Only block if it truly doesn't exist and isn't the env's version
        echo "Error: python${version} is not available in this environment"
        echo ""
        if [[ -n "$venv_version" ]]; then
            echo "This environment uses Python ${venv_version}"
            echo "   Available: python, python3, python${venv_version}"
        else
            echo "Unable to determine the active environment's Python version"
            echo "   Available: python, python3"
        fi
        echo ""
        echo "To use a different Python version, deactivate first with: deactivate"
        return 1
    fi

    # Outside venv: ensure we have scanned for pythons
    _scan_all_pythons

    # Check if trying to use pip module (blocked unless build mode)
    if [[ "$#" -ge 2 ]] && [[ "$1" == "-m" ]] && [[ "$2" == "pip" ]]; then
        if [[ $_PYTHON_BUILD_MODE -eq 1 ]]; then
            # Build mode: allow python3.X -m pip
            if [[ -n "${_PYTHON_PATHS[$version]}" ]]; then
                echo "[build mode] Running python${version} -m pip..." >&2
                "${_PYTHON_PATHS[$version]}" "$@"
                return $?
            fi
        else
            echo "Error: python${version} -m pip is blocked outside virtual environments"
            echo ""
            echo "To use pip:"
            echo "   1. Create a virtual environment: python${version} -m venv [venv-projname]"
            echo "   2. Activate it: source [venv-projname]/bin/activate"
            echo "   3. Then use pip normally"
            echo ""
            echo "This prevents accidental system-wide package installations."
            echo "Tip: Use 'setpy ${version} --build' to temporarily allow pip."
            return 1
        fi
    fi

    # Check if this version exists
    if [[ -z "${_PYTHON_PATHS[$version]}" ]]; then
        echo "Error: python${version} not found on this system"
        return 1
    fi
    
    # Allow all other python usage
    "${_PYTHON_PATHS[$version]}" "$@"
}

# Pip version-specific wrapper
_pip_version_wrapper() {
    local version="$1"
    shift

    # CRITICAL: Check if helper functions exist (for sandboxed environments)
    if ! typeset -f _py_manager_should_bypass >/dev/null 2>&1 || \
       ! typeset -f _py_manager_available >/dev/null 2>&1; then
        # Functions not loaded, just use system pip
        command "pip${version}" "$@"
        return $?
    fi

    if _py_manager_should_bypass; then
        # VENV ENFORCEMENT: Block mismatched pip versions even in bypass mode
        if [[ -n "${VIRTUAL_ENV:-}" ]] && [[ -d "$VIRTUAL_ENV/bin" ]]; then
            local venv_ver=$(_get_venv_version_fast)
            if [[ -n "$venv_ver" ]] && [[ "$version" != "$venv_ver" ]]; then
                echo "Error: pip${version} blocked - venv uses Python ${venv_ver}" >&2
                echo "" >&2
                echo "This would install to system Python ${version}, not your venv." >&2
                echo "Use 'pip' or 'pip3' instead." >&2
                return 1
            fi
            # Version matches - use venv's pip to ensure correct sys.prefix
            if [[ -x "$VIRTUAL_ENV/bin/pip" ]]; then
                "$VIRTUAL_ENV/bin/pip" "$@"
                return $?
            fi
        fi

        # Original bypass logic for outside venv
        if _py_manager_available; then
            _scan_all_pythons
            if [[ -n "${_PYTHON_PATHS[$version]}" ]]; then
                local pip_path="${_PYTHON_PATHS[$version]%/*}/pip${version}"
                if [[ -x "$pip_path" ]]; then
                    "$pip_path" "$@"
                    return $?
                fi
            fi
        fi
        command "pip${version}" "$@"
        return $?
    fi

    if ! _py_manager_available; then
        command "pip${version}" "$@"
        return $?
    fi

    # If in venv, be more permissive
    if _in_virtual_env; then
        local env_bin_dir=$(_py_manager_env_bin_dir 2>/dev/null)

        # First check if the requested pip executable exists in the active env
        if [[ -n "$env_bin_dir" ]] && [[ -x "$env_bin_dir/pip${version}" ]]; then
            # It exists! Just use it directly
            "$env_bin_dir/pip${version}" "$@"
            return $?
        fi
        
        # If not found, check if this matches the venv's major.minor version
        local venv_version=$(_get_venv_python_version)
        
        # Extract just major.minor from the full version if needed
        if [[ "$venv_version" =~ ^([0-9]+\.[0-9]+) ]]; then
            venv_version="${match[1]}"
        fi
        
        if [[ -n "$venv_version" ]] && [[ "$version" == "$venv_version" ]]; then
            # Fall back to the env's pip
            if [[ -n "$env_bin_dir" ]] && [[ -x "$env_bin_dir/pip" ]]; then
                "$env_bin_dir/pip" "$@"
                return $?
            fi
            command pip "$@"
            return $?
        fi

        echo "Error: pip${version} is not available in this environment"
        echo ""
        if [[ -n "$venv_version" ]]; then
            echo "This environment uses Python ${venv_version}"
            echo "   Available: pip, pip3, pip${venv_version}"
        else
            echo "Unable to determine the active environment's Python version"
            echo "   Available: pip, pip3"
        fi
        echo ""
        echo "To use a different Python version, deactivate first with: deactivate"
        return 1
    fi

    # Build mode: allow pip with the specified version
    if [[ $_PYTHON_BUILD_MODE -eq 1 ]]; then
        _scan_all_pythons
        if [[ -n "${_PYTHON_PATHS[$version]}" ]]; then
            echo "[build mode] Running pip${version} with Python ${version}..." >&2
            "${_PYTHON_PATHS[$version]}" -m pip "$@"
            return $?
        fi
    fi

    # Outside venv: block
    echo "Error: pip${version} is not available outside virtual environments"
    echo ""
    echo "To use pip:"
    echo "   1. Create a virtual environment: python${version} -m venv [venv-projname]"
    echo "   2. Activate it: source [venv-projname]/bin/activate"
    echo "   3. Then use pip normally"
    echo ""
    echo "This prevents accidental system-wide package installations."
    if [[ -n "$_PYTHON_OVERRIDE" ]]; then
        echo ""
        echo "Tip: Use 'setpy ${_PYTHON_OVERRIDE} --build' to temporarily allow pip."
    fi
    return 1
}

# Create version functions for a wide range (covers current and future Python versions)
# Note: The wrapper functions handle non-existent versions gracefully with helpful error messages
# This range (3.8-3.25) should cover Python releases for many years to come
for major in 3; do
    for minor in {8..25}; do
        ver="${major}.${minor}"
        # Validate version format to prevent code injection via eval
        if [[ "$ver" =~ ^[0-9]+\.[0-9]+$ ]]; then
            eval "
python${ver}() {
    if typeset -f _python_version_wrapper >/dev/null 2>&1; then
        _python_version_wrapper '${ver}' \"\$@\"
    else
        command python${ver} \"\$@\"
    fi
}
"
            eval "
py${ver}() {
    if typeset -f _python_version_wrapper >/dev/null 2>&1; then
        _python_version_wrapper '${ver}' \"\$@\"
    else
        command python${ver} \"\$@\"
    fi
}
"
            eval "
pip${ver}() {
    if typeset -f _pip_version_wrapper >/dev/null 2>&1; then
        _pip_version_wrapper '${ver}' \"\$@\"
    else
        command pip${ver} \"\$@\"
    fi
}
"
        fi
    done
done

# Diagnostic command for debugging sandboxing issues
pydiag() {
    echo "Python Manager Diagnostics:"
    echo ""
    echo "Environment Variables:"
    echo "  PYTHON_MANAGER_FORCE_BYPASS=${PYTHON_MANAGER_FORCE_BYPASS:-<not set>}"
    echo "  CI=${CI:-<not set>}"
    echo "  CODEX_SANDBOX_NETWORK_DISABLED=${CODEX_SANDBOX_NETWORK_DISABLED:-<not set>}"
    echo "  VIRTUAL_ENV=${VIRTUAL_ENV:-<not set>}"
    echo "  CONDA_PREFIX=${CONDA_PREFIX:-<not set>}"
    echo "  CONDA_DEFAULT_ENV=${CONDA_DEFAULT_ENV:-<not set>}"
    echo "  SHLVL=$SHLVL"
    echo ""
    echo "Shell Properties:"
    echo "  Interactive: $([[ -o interactive ]] && echo 'yes' || echo 'no')"
    echo "  Login shell: $([[ -o login ]] && echo 'yes' || echo 'no')"
    echo ""
    echo "Function Availability:"
    echo "  _py_manager_available: $(typeset -f _py_manager_available >/dev/null 2>&1 && echo 'loaded' || echo 'missing')"
    echo "  _py_manager_should_bypass: $(typeset -f _py_manager_should_bypass >/dev/null 2>&1 && echo 'loaded' || echo 'missing')"
    echo "  _in_virtual_env: $(typeset -f _in_virtual_env >/dev/null 2>&1 && echo 'loaded' || echo 'missing')"
    echo "  _scan_all_pythons: $(typeset -f _scan_all_pythons >/dev/null 2>&1 && echo 'loaded' || echo 'missing')"
    echo ""
    echo "Manager State:"
    echo "  _PYTHON_MANAGER_READY=${_PYTHON_MANAGER_READY:-0}"
    echo "  _PYTHONS_SCANNED=${_PYTHONS_SCANNED:-0}"
    echo "  _PYTHON_OVERRIDE=${_PYTHON_OVERRIDE:-<not set>}"
    echo "  _PYTHON_BUILD_MODE=${_PYTHON_BUILD_MODE:-0}"
    echo ""

    if typeset -f _py_manager_should_bypass >/dev/null 2>&1; then
        if _py_manager_should_bypass; then
            echo "Bypass Mode: ACTIVE (will use system commands)"
        else
            echo "Bypass Mode: INACTIVE (will use wrapper logic)"
        fi
    else
        echo "Bypass Mode: Cannot determine (function not loaded)"
    fi
    echo ""

    if typeset -f _in_virtual_env >/dev/null 2>&1; then
        if _in_virtual_env; then
            echo "Virtual Environment: DETECTED"
        else
            echo "Virtual Environment: NOT DETECTED"
        fi
    else
        echo "Virtual Environment: Cannot determine (function not loaded)"
    fi
    echo ""

    if [[ $_PYTHON_BUILD_MODE -eq 1 ]]; then
        echo "Build Mode: ENABLED (pip allowed outside venv)"
    else
        echo "Build Mode: DISABLED (pip blocked outside venv)"
    fi
    echo ""

    echo "Python Commands Available:"
    echo "  python: $(whence -p python 2>/dev/null || echo '<function/not found>')"
    echo "  python3: $(whence -p python3 2>/dev/null || echo '<function/not found>')"
    echo "  pip: $(whence -p pip 2>/dev/null || echo '<function/not found>')"
    echo ""
    echo "  Use 'pywhich python' to see what binary would actually run."
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Subprocess/AI Tool Compatibility (Codex CLI, Claude Code, etc.):"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Exported Environment Variables (inherited by subprocesses):"
    echo "  PYTHON=${PYTHON:-<not set>}"
    echo "  PYTHON3=${PYTHON3:-<not set>}"
    echo "  PIP_REQUIRE_VIRTUALENV=${PIP_REQUIRE_VIRTUALENV:-<not set>}"
    echo ""
    echo "NOTE: Subprocesses do not inherit shell functions; they rely on PATH/ENV."
    echo "      'setpy' exports PYTHON/PYTHON3 and updates PATH."
    echo ""

    echo "What subprocesses will see:"
    echo "  'python' command: $(command -v python 2>/dev/null || echo 'not found')"
    echo "  'python3' command: $(command -v python3 2>/dev/null || echo 'not found')"
    echo "  PYTHON env var: ${PYTHON:-<not set>}"
    echo "  PYTHON3 env var: ${PYTHON3:-<not set>}"
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Troubleshooting:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "If Codex CLI/Claude Code can't find Python:"
    echo "   1. Run: setpy <version>  (exports PYTHON/PYTHON3 env vars)"
    echo "   2. AI tools that respect these env vars will use the right Python"
    echo "   3. For tools that only use PATH, add Python's bin dir to PATH:"
    echo "      export PATH=\"/path/to/python/bin:\$PATH\""
    echo ""
    echo "If in a sandboxed environment and seeing errors:"
    echo "   1. Set: export PYTHON_MANAGER_FORCE_BYPASS=1"
    echo "   2. Or reload your shell configuration"
    echo "   3. The script should auto-detect sandboxing and bypass safely"
}

# Enhanced pyinfo function
pyinfo() {
    if ! _py_manager_available; then
        echo "Warning: Python manager helpers unavailable; pyinfo cannot run"
        return 1
    fi

    echo "Python Environment Status:"
    echo ""
    
    # Show override if set
    if [[ -n "$_PYTHON_OVERRIDE" ]]; then
        echo "Temporary Python Override Active: ${_PYTHON_OVERRIDE}"
        echo "   'python' and 'python3' -> python${_PYTHON_OVERRIDE}"
        echo "   (use 'setpy clear' to remove)"
        echo ""
    fi

    # Check virtual environment status
    if _in_virtual_env; then
        echo "Virtual Environment Active"
        echo ""
        
        local venv_version=$(_get_venv_python_version)
        
        if [[ -n "$VIRTUAL_ENV" ]]; then
            echo "  Type: venv/virtualenv"
            echo "  Path: $VIRTUAL_ENV"
            echo "  Python version: ${venv_version:-unknown}"
        elif [[ -n "$CONDA_DEFAULT_ENV" ]]; then
            echo "  Type: conda"
            echo "  Name: $CONDA_DEFAULT_ENV"
            echo "  Python version: ${venv_version:-unknown}"
        elif [[ -n "$POETRY_ACTIVE" ]]; then
            echo "  Type: poetry"
        elif [[ -n "$PIPENV_ACTIVE" ]]; then
            echo "  Type: pipenv"
        fi
        
        echo ""
        echo "  Available commands in this venv:"
        echo "    python     -> $(pywhich python 2>/dev/null)"
        echo "    python3    -> $(pywhich python3 2>/dev/null)"
        if [[ -n "$venv_version" ]]; then
            echo "    python${venv_version} -> $(pywhich python${venv_version} 2>/dev/null)"
        fi
        echo "    pip        -> $(pywhich pip 2>/dev/null)"
        echo "    pip3       -> $(pywhich pip3 2>/dev/null)"
        if [[ -n "$venv_version" ]]; then
            echo "    pip${venv_version}    -> $(pywhich pip${venv_version} 2>/dev/null)"
        fi
        echo ""
        echo "  Note: Other Python versions are blocked while venv is active."
        echo ""
        echo "────────────────────────────────"
        echo ""
    else
        echo "No Virtual Environment Active"
        echo ""
    fi
    
    _scan_all_pythons
    
    if (( ${#_PYTHON_VERSIONS} == 0 )); then
        echo "No Python 3.x found on system"
    else
        echo "System Python Versions:"
        for ver in $_PYTHON_VERSIONS; do
            echo ""
            echo "  Python $ver:"
            echo "    Path: ${_PYTHON_PATHS[$ver]}"
            echo "    Info: ${_PYTHON_INFO[$ver]}"
            echo "    Usage: python${ver} -m venv <venv-name>"
            if [[ "$ver" == "$_PYTHON_OVERRIDE" ]]; then
                echo "    Status: * Currently set as override"
            fi
        done
        echo ""
        echo "Note: pip is blocked for all system Python versions."
        echo "Always use virtual environments for package management."
    fi
}
# pywhich - Show actual binary paths for python/pip commands
# Usage: pywhich python3.X [pip3.X ...]
pywhich() {
    if [[ $# -eq 0 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
        _scan_all_pythons
        local example_ver="${_PYTHON_VERSIONS[-1]:-3.x}"
        local example_ver2="${_PYTHON_VERSIONS[1]:-3.x}"
        echo "Usage: pywhich <command> [command ...]"
        echo ""
        echo "Shows the actual binary path that would be executed for python/pip commands."
        echo "Unlike 'which', this resolves through the Python manager's logic."
        echo ""
        echo "Examples:"
        echo "   pywhich python${example_ver}     # → /path/to/python${example_ver}"
        echo "   pywhich python         # → shows override or venv python"
        echo "   pywhich pip            # → (blocked outside venv)"
        echo "   pywhich python${example_ver2} pip  # check multiple commands"
        echo ""
        echo "Related commands:"
        echo "   which <cmd>            Enhanced which (uses pywhich for python/pip)"
        echo "   pyinfo                 Show all Python versions and status"
        echo "   setpy <version>        Set temporary Python default"
        return 0
    fi

    if ! _py_manager_available; then
        # Fall back to command which if manager not fully loaded
        for cmd in "$@"; do
            command which "$cmd" 2>/dev/null || echo "$cmd: not found"
        done
        return $?
    fi

    _scan_all_pythons
    local had_error=0

    for cmd in "$@"; do
        local result=""
        local in_env=0
        local env_bin_dir=""
        if _in_virtual_env; then
            in_env=1
            env_bin_dir=$(_py_manager_env_bin_dir 2>/dev/null)
        fi

        case "$cmd" in
            python|python3)
                if (( in_env )); then
                    if [[ -n "$env_bin_dir" ]] && [[ -x "$env_bin_dir/$cmd" ]]; then
                        result="$env_bin_dir/$cmd"
                    else
                        result=$(whence -p "$cmd" 2>/dev/null)
                    fi
                    if [[ -z "$result" ]]; then
                        result="(not found in environment)"
                        had_error=1
                    fi
                elif [[ -n "$_PYTHON_OVERRIDE" ]] && [[ -n "${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}" ]]; then
                    result="${_PYTHON_PATHS[$_PYTHON_OVERRIDE]}"
                else
                    result="(blocked - use explicit version or setpy)"
                    had_error=1
                fi
                ;;
            python[0-9].[0-9]*|py[0-9].[0-9]*)
                local version=""
                if [[ "$cmd" =~ ^python([0-9]+\.[0-9]+)$ ]]; then
                    version="${match[1]}"
                elif [[ "$cmd" =~ ^py([0-9]+\.[0-9]+)$ ]]; then
                    version="${match[1]}"
                fi

                if [[ -n "$version" ]]; then
                    # Check venv first
                    if (( in_env )); then
                        local venv_version=$(_get_venv_python_version)
                        if [[ -n "$env_bin_dir" ]] && [[ -x "$env_bin_dir/python${version}" ]]; then
                            result="$env_bin_dir/python${version}"
                        elif [[ "$version" == "$venv_version" ]]; then
                            if [[ -n "$env_bin_dir" ]] && [[ -x "$env_bin_dir/python" ]]; then
                                result="$env_bin_dir/python"
                            else
                                result=$(whence -p python 2>/dev/null)
                            fi
                        else
                            result="(not available in env - env uses Python $venv_version)"
                            had_error=1
                        fi
                        if [[ -z "$result" ]]; then
                            result="(not found in environment)"
                            had_error=1
                        fi
                    elif [[ -n "${_PYTHON_PATHS[$version]}" ]]; then
                        result="${_PYTHON_PATHS[$version]}"
                    else
                        result="(not found)"
                        had_error=1
                    fi
                fi
                ;;
            pip|pip3)
                if (( in_env )); then
                    if [[ -n "$env_bin_dir" ]] && [[ -x "$env_bin_dir/$cmd" ]]; then
                        result="$env_bin_dir/$cmd"
                    else
                        result=$(whence -p "$cmd" 2>/dev/null)
                    fi
                    if [[ -z "$result" ]]; then
                        result="(not found in environment)"
                        had_error=1
                    fi
                else
                    result="(blocked outside venv)"
                    had_error=1
                fi
                ;;
            pip[0-9].[0-9]*)
                local version=""
                if [[ "$cmd" =~ ^pip([0-9]+\.[0-9]+)$ ]]; then
                    version="${match[1]}"
                fi

                if [[ -n "$version" ]] && (( in_env )); then
                    local venv_version=$(_get_venv_python_version)
                    if [[ -n "$env_bin_dir" ]] && [[ -x "$env_bin_dir/pip${version}" ]]; then
                        result="$env_bin_dir/pip${version}"
                    elif [[ "$version" == "$venv_version" ]]; then
                        if [[ -n "$env_bin_dir" ]] && [[ -x "$env_bin_dir/pip" ]]; then
                            result="$env_bin_dir/pip"
                        else
                            result=$(whence -p pip 2>/dev/null)
                        fi
                    else
                        result="(not available in env)"
                        had_error=1
                    fi
                    if [[ -z "$result" ]]; then
                        result="(not found in environment)"
                        had_error=1
                    fi
                else
                    result="(blocked outside venv)"
                    had_error=1
                fi
                ;;
            *)
                # Not a python/pip command, use real which
                result=$(command which "$cmd" 2>/dev/null)
                if [[ -z "$result" ]]; then
                    result="(not found)"
                    had_error=1
                fi
                ;;
        esac

        if [[ $# -eq 1 ]]; then
            echo "$result"
        else
            echo "$cmd: $result"
        fi
    done

    return $had_error
}

# which - wrapper that uses pywhich for python/pip commands
# Passes through to real which for everything else
which() {
    # Help option
    if [[ "$1" == "--pyhelp" ]]; then
        _scan_all_pythons
        local example_ver="${_PYTHON_VERSIONS[-1]:-3.x}"
        echo "which - enhanced with Python version manager support"
        echo ""
        echo "For python/pip commands, shows the actual binary path:"
        echo "   which python${example_ver}  → /path/to/python${example_ver}"
        echo "   which pip         → (blocked outside venv)"
        echo ""
        echo "For other commands, uses standard 'which' behavior."
        echo ""
        echo "Related commands:"
        echo "   pywhich <cmd>     Show path for python/pip commands"
        echo "   pyinfo            Show all Python versions and status"
        echo "   setpy <version>   Set temporary Python default"
        echo "   pydiag            Debug Python manager issues"
        return 0
    fi

    # If any options are passed (-a, -s, etc.), use real which
    if [[ "$1" == -* ]]; then
        command which "$@"
        return $?
    fi

    # Single argument - check if it's a python/pip command we manage
    if [[ $# -eq 1 ]]; then
        local cmd="$1"
        
        # Exact matches for base commands
        if [[ "$cmd" == "python" || "$cmd" == "python3" || \
              "$cmd" == "pip" || "$cmd" == "pip3" ]]; then
            pywhich "$cmd"
            return $?
        fi
        
        # Version-specific: python3.X, py3.X, pip3.X patterns
        if [[ "$cmd" =~ ^(python|py|pip)[0-9]+\.[0-9]+$ ]]; then
            pywhich "$cmd"
            return $?
        fi
    fi

    # Multiple args or non-python command - use real which
    command which "$@"
}

(( _PYTHON_MANAGER_READY = 1 ))


# Clear inherited build mode when starting a new interactive shell session.
# This prevents "build mode" from leaking into child shells via exported env vars.
if [[ -o interactive ]]; then
  if [[ "${PYMANAGER_SESSION_PID:-}" != "$$" ]]; then
    if [[ "${PYMANAGER_BUILD_MODE:-}" == "1" ]]; then
      [[ -n "${PYMANAGER_DEBUG:-}" ]] && echo "[pymanager] Clearing inherited build mode for new shell session" >&2
      _PYTHON_BUILD_MODE=0
      _PYMANAGER_SAVED_PIP_REQUIRE_VIRTUALENV_SET=0
      _PYMANAGER_SAVED_PIP_REQUIRE_VIRTUALENV=""

      if [[ "${PYMANAGER_SAVED_PIP_REQUIRE_VIRTUALENV_SET:-0}" == "1" ]]; then
        export PIP_REQUIRE_VIRTUALENV="${PYMANAGER_SAVED_PIP_REQUIRE_VIRTUALENV}"
      else
        unset PIP_REQUIRE_VIRTUALENV
      fi
      unset PYMANAGER_BUILD_MODE PYMANAGER_SAVED_PIP_REQUIRE_VIRTUALENV_SET PYMANAGER_SAVED_PIP_REQUIRE_VIRTUALENV
    fi

    export PYMANAGER_SESSION_PID="$$"
  fi
fi
