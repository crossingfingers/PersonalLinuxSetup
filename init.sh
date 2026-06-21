#!/usr/bin/env bash
#
# setup.sh — Dev environment bootstrap
#
# Installs:
#   - Python 3 (latest available via package manager) + pip
#   - tmux
#   - fzf
#   - xclip
#   - zsh
#   - oh-my-zsh with the "crunch" theme
#   - Go (latest stable, via official tarball)
#   - Claude Code (official native installer)
#
# Supports Debian/Ubuntu (apt), Fedora/RHEL (dnf), and Arch (pacman).
# Run with: bash setup.sh
# (Sudo privileges required — script will prompt as needed.)
#
# Design note: this script does NOT use `set -e`. Every step is independent —
# if one install fails, the script logs it and moves on to the rest, then
# prints a full status report at the end.

set -uo pipefail

# ---------- helpers ----------

log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$1"; }
err()  { printf '\033[1;31m[err]\033[0m %s\n' "$1" >&2; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$1"; }

# ---------- status tracking ----------
# Arrays of "label" strings, appended to as steps succeed or fail.
STATUS_OK=()
STATUS_FAIL=()
STATUS_SKIP=()

mark_ok()   { STATUS_OK+=("$1");   ok "$1"; }
mark_fail() { STATUS_FAIL+=("$1"); err "$1 failed"; }
mark_skip() { STATUS_SKIP+=("$1"); warn "$1 skipped: $2"; }

# Run a command for a given step label. Never aborts the script.
# Usage: run_step "Label" cmd arg1 arg2 ...
run_step() {
    local label="$1"; shift
    log "Installing: $label"
    if "$@"; then
        mark_ok "$label"
        return 0
    else
        mark_fail "$label"
        return 1
    fi
}

# ---------- sudo check ----------

if ! command -v sudo >/dev/null 2>&1; then
    err "sudo is not installed and is required for this script. Aborting."
    exit 1
fi

# ---------- detect package manager ----------

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    else
        echo "unknown"
    fi
}

PKG_MANAGER=$(detect_pkg_manager)

if [ "$PKG_MANAGER" = "unknown" ]; then
    err "Could not detect a supported package manager (apt, dnf, pacman). Aborting."
    exit 1
fi

log "Detected package manager: $PKG_MANAGER"

# ---------- package manager update (best-effort, non-fatal) ----------

case "$PKG_MANAGER" in
    apt)
        log "Updating apt package index..."
        if sudo apt-get update -y; then
            mark_ok "apt package index update"
        else
            mark_fail "apt package index update"
            warn "Continuing anyway — installs below may use a stale index or fail."
        fi
        ;;
    pacman)
        log "Syncing pacman package database..."
        if sudo pacman -Sy --noconfirm; then
            mark_ok "pacman database sync"
        else
            mark_fail "pacman database sync"
            warn "Continuing anyway — installs below may use a stale index or fail."
        fi
        ;;
    dnf)
        : # dnf refreshes metadata automatically per-install; nothing to do upfront
        ;;
esac

# ---------- per-package-manager install function ----------
#
# install_pkg <label> <pkg-name...>
# Installs one logical package (which may map to multiple actual package
# names) and records success/failure. Each call is independent of the others.

install_pkg() {
    local label="$1"; shift
    local pkgs=("$@")

    case "$PKG_MANAGER" in
        apt)
            run_step "$label" sudo apt-get install -y "${pkgs[@]}"
            ;;
        dnf)
            run_step "$label" sudo dnf install -y "${pkgs[@]}"
            ;;
        pacman)
            run_step "$label" sudo pacman -S --noconfirm "${pkgs[@]}"
            ;;
    esac
}

# ---------- install each component individually ----------

case "$PKG_MANAGER" in
    apt)
        install_pkg "Python 3 + pip + venv" python3 python3-pip python3-venv
        ;;
    dnf)
        install_pkg "Python 3 + pip" python3 python3-pip
        ;;
    pacman)
        install_pkg "Python 3 + pip" python python-pip
        ;;
esac

install_pkg "tmux" tmux
install_pkg "fzf" fzf
install_pkg "xclip" xclip
install_pkg "zsh" zsh

# git and curl are required by later steps (oh-my-zsh install), so install
# them too, individually, and track them.
install_pkg "git" git
install_pkg "curl" curl

# ---------- verify python/pip, with fallback ----------

log "Verifying Python and pip installation..."
if command -v python3 >/dev/null 2>&1; then
    ok "python3 found: $(python3 --version 2>&1)"
else
    mark_fail "python3 binary check"
fi

if command -v pip3 >/dev/null 2>&1; then
    ok "pip3 found: $(pip3 --version 2>&1)"
else
    warn "pip3 not found on PATH, attempting fallback bootstrap with ensurepip..."
    if command -v python3 >/dev/null 2>&1 && python3 -m ensurepip --upgrade; then
        mark_ok "pip bootstrap via ensurepip"
    else
        mark_fail "pip bootstrap via ensurepip"
    fi
fi

# Upgrade pip to the latest version for the user (best-effort, non-fatal)
if command -v python3 >/dev/null 2>&1; then
    if python3 -m pip install --upgrade pip --user; then
        mark_ok "pip upgrade to latest"
    else
        mark_fail "pip upgrade to latest"
    fi
fi

# ---------- install oh-my-zsh ----------

OMZ_DIR="${HOME}/.oh-my-zsh"

if [ -d "$OMZ_DIR" ]; then
    mark_skip "oh-my-zsh install" "already installed at $OMZ_DIR"
else
    if ! command -v curl >/dev/null 2>&1; then
        mark_fail "oh-my-zsh install (curl unavailable)"
    else
        log "Installing oh-my-zsh..."
        # --unattended prevents it from changing shell or launching zsh automatically,
        # and avoids interactive prompts.
        if RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c \
            "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended; then
            mark_ok "oh-my-zsh install"
        else
            mark_fail "oh-my-zsh install"
        fi
    fi
fi

# ---------- install crunch theme ----------
#
# "crunch" is not a built-in oh-my-zsh theme, so this generates a crunchpunk-style
# custom theme and drops it into the custom themes directory. If oh-my-zsh
# itself failed to install above, this step will still try (it only needs the
# directory structure), but it's tracked independently either way.

CUSTOM_THEMES_DIR="${OMZ_DIR}/custom/themes"
THEME_FILE="${CUSTOM_THEMES_DIR}/crunch.zsh-theme"

if mkdir -p "$CUSTOM_THEMES_DIR" 2>/dev/null && [ -f "$THEME_FILE" ]; then
    mark_skip "crunch theme install" "already exists at $THEME_FILE"
elif mkdir -p "$CUSTOM_THEMES_DIR" 2>/dev/null; then
    log "Installing 'crunch' theme..."
    if cat > "$THEME_FILE" << 'EOF'
# crunch.zsh-theme — minimal crunchpunk-style prompt for oh-my-zsh

local ret_status="%(?:%{$fg_bold[green]%}➜:%{$fg_bold[red]%}➜)"

PROMPT='%{$fg_bold[magenta]%}%n%{$reset_color%}@%{$fg_bold[cyan]%}%m \
%{$fg[green]%}%~ \
${ret_status}%{$reset_color%} '

RPROMPT='%{$fg[yellow]%}[%*]%{$reset_color%}'

ZSH_THEME_GIT_PROMPT_PREFIX="%{$fg_bold[blue]%}git:(%{$fg[red]%}"
ZSH_THEME_GIT_PROMPT_SUFFIX="%{$reset_color%} "
ZSH_THEME_GIT_PROMPT_DIRTY="%{$fg[blue]%}) %{$fg[yellow]%}✗"
ZSH_THEME_GIT_PROMPT_CLEAN="%{$fg[blue]%})"
EOF
    then
        mark_ok "crunch theme install"
    else
        mark_fail "crunch theme install"
    fi
else
    mark_fail "crunch theme install (could not create themes directory)"
fi

# ---------- configure .zshrc ----------

ZSHRC="${HOME}/.zshrc"

if [ -f "$ZSHRC" ]; then
    log "Setting ZSH_THEME to 'crunch' in $ZSHRC..."
    if grep -q '^ZSH_THEME=' "$ZSHRC"; then
        if sed -i.bak 's/^ZSH_THEME=.*/ZSH_THEME="crunch"/' "$ZSHRC"; then
            mark_ok ".zshrc theme configuration"
        else
            mark_fail ".zshrc theme configuration"
        fi
    else
        if echo 'ZSH_THEME="crunch"' >> "$ZSHRC"; then
            mark_ok ".zshrc theme configuration"
        else
            mark_fail ".zshrc theme configuration"
        fi
    fi
else
    warn "$ZSHRC not found, creating a minimal one."
    if cat > "$ZSHRC" << 'EOF'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="crunch"
plugins=(git)
source $ZSH/oh-my-zsh.sh
EOF
    then
        mark_ok ".zshrc creation"
    else
        mark_fail ".zshrc creation"
    fi
fi

# Add fzf shell integration (best-effort, non-fatal)
if [ -f "$ZSHRC" ]; then
    if ! grep -q 'fzf --zsh' "$ZSHRC" 2>/dev/null; then
        if {
            echo ''
            echo '# fzf keybindings and completion'
            echo 'if command -v fzf >/dev/null 2>&1; then'
            echo '  source <(fzf --zsh) 2>/dev/null || true'
            echo 'fi'
        } >> "$ZSHRC"; then
            mark_ok "fzf shell integration in .zshrc"
        else
            mark_fail "fzf shell integration in .zshrc"
        fi
    else
        mark_skip "fzf shell integration in .zshrc" "already present"
    fi
fi

# ---------- set zsh as default shell (best-effort, non-fatal) ----------

if command -v zsh >/dev/null 2>&1; then
    ZSH_PATH="$(command -v zsh)"
    if [ "${SHELL:-}" = "$ZSH_PATH" ]; then
        mark_skip "set zsh as default shell" "already the default"
    else
        log "Setting zsh as the default shell for $USER..."
        if chsh -s "$ZSH_PATH" "$USER"; then
            mark_ok "set zsh as default shell"
        else
            mark_fail "set zsh as default shell (try manually: chsh -s $ZSH_PATH)"
        fi
    fi
else
    mark_fail "set zsh as default shell (zsh binary not found)"
fi

# ---------- install Go (latest stable, via official tarball) ----------
#
# Distro package managers often lag behind upstream Go releases, so this
# downloads the current stable tarball directly from go.dev, same philosophy
# as "latest python" above. Falls back gracefully if curl/tar are missing or
# the download fails — never aborts the rest of the script.

install_go() {
    local label="Go (golang)"
    log "Installing: $label"

    if ! command -v curl >/dev/null 2>&1; then
        mark_fail "$label (curl unavailable)"
        return
    fi

    # Detect architecture
    local arch
    case "$(uname -m)" in
        x86_64|amd64)   arch="amd64" ;;
        aarch64|arm64)  arch="arm64" ;;
        armv6l)         arch="armv6l" ;;
        armv7l)         arch="armv6l" ;;
        i386|i686)      arch="386" ;;
        *)
            mark_fail "$label (unsupported architecture: $(uname -m))"
            return
            ;;
    esac

    # Detect latest version from go.dev
    local go_version
    go_version="$(curl -sL https://go.dev/VERSION?m=text 2>/dev/null | head -n1)"
    if [ -z "$go_version" ]; then
        mark_fail "$label (could not detect latest version from go.dev)"
        return
    fi

    local tarball="${go_version}.linux-${arch}.tar.gz"
    local tmp_path="/tmp/${tarball}"
    local download_url="https://go.dev/dl/${tarball}"

    log "Downloading ${download_url}..."
    if ! curl -fsSL "$download_url" -o "$tmp_path"; then
        mark_fail "$label (download failed for $download_url)"
        return
    fi

    log "Extracting Go to /usr/local/go..."
    if ! sudo rm -rf /usr/local/go; then
        mark_fail "$label (could not remove existing /usr/local/go)"
        rm -f "$tmp_path"
        return
    fi

    if ! sudo tar -C /usr/local -xzf "$tmp_path"; then
        mark_fail "$label (tarball extraction failed)"
        rm -f "$tmp_path"
        return
    fi

    rm -f "$tmp_path"

    # Add Go to PATH for future shell sessions (bash + zsh), idempotently
    local go_path_line='export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin'
    local profile_file
    for profile_file in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
        if [ -f "$profile_file" ]; then
            if ! grep -qF '/usr/local/go/bin' "$profile_file" 2>/dev/null; then
                {
                    echo ''
                    echo '# Go (golang)'
                    echo "$go_path_line"
                } >> "$profile_file"
            fi
        else
            {
                echo "$go_path_line"
            } >> "$profile_file"
        fi
    done

    # Verify using the freshly extracted binary directly (PATH won't be
    # updated in this running shell until a new session starts)
    if /usr/local/go/bin/go version >/dev/null 2>&1; then
        mark_ok "$label ($(/usr/local/go/bin/go version 2>&1))"
    else
        mark_fail "$label (binary did not run after extraction)"
    fi
}

install_go

# ---------- install Claude Code ----------
#
# Uses Anthropic's official native installer (no Node.js dependency,
# auto-updates in background). Falls back to npm if curl-based install fails
# and npm/Node.js happen to be available, but does not install Node.js itself
# since that's outside this script's scope.

install_claude_code() {
    local label="Claude Code"

    if command -v claude >/dev/null 2>&1; then
        mark_skip "$label" "already installed ($(claude --version 2>&1 | head -n1))"
        return
    fi

    if ! command -v curl >/dev/null 2>&1; then
        mark_fail "$label (curl unavailable)"
        return
    fi

    log "Installing: $label (native installer)"
    if curl -fsSL https://claude.ai/install.sh | bash; then
        # The installer places the binary under ~/.local/bin or similar and
        # updates shell rc files itself, but PATH won't refresh in this
        # running shell. Try common locations to confirm install succeeded.
        if command -v claude >/dev/null 2>&1 || [ -x "${HOME}/.local/bin/claude" ]; then
            mark_ok "$label"
        else
            mark_ok "$label (installed — open a new shell session for 'claude' to be on PATH)"
        fi
        return
    fi

    mark_fail "$label (native installer failed)"

    # Fallback: try npm if it's already present on the system
    if command -v npm >/dev/null 2>&1; then
        warn "Attempting npm fallback install for Claude Code..."
        if npm install -g @anthropic-ai/claude-code; then
            mark_ok "$label (npm fallback)"
        else
            mark_fail "$label (npm fallback)"
        fi
    else
        warn "npm not available for fallback install. Install Node.js 18+ and run: npm install -g @anthropic-ai/claude-code"
    fi
}

install_claude_code

# ---------- final status report ----------

echo
echo "============================================"
echo "             INSTALLATION REPORT             "
echo "============================================"

if [ "${#STATUS_OK[@]}" -gt 0 ]; then
    printf '\n\033[1;32mSucceeded (%d):\033[0m\n' "${#STATUS_OK[@]}"
    for item in "${STATUS_OK[@]}"; do
        echo "  ✔ $item"
    done
fi

if [ "${#STATUS_SKIP[@]}" -gt 0 ]; then
    printf '\n\033[1;33mSkipped (%d):\033[0m\n' "${#STATUS_SKIP[@]}"
    for item in "${STATUS_SKIP[@]}"; do
        echo "  ↷ $item"
    done
fi

if [ "${#STATUS_FAIL[@]}" -gt 0 ]; then
    printf '\n\033[1;31mFailed (%d):\033[0m\n' "${#STATUS_FAIL[@]}"
    for item in "${STATUS_FAIL[@]}"; do
        echo "  ✘ $item"
    done
fi

echo
echo "Installed tool versions (where available):"
echo "  python3 : $(python3 --version 2>&1 || echo 'not found')"
echo "  pip3    : $(pip3 --version 2>&1 || echo 'not found')"
echo "  tmux    : $(tmux -V 2>&1 || echo 'not found')"
echo "  fzf     : $(fzf --version 2>&1 || echo 'not found')"
echo "  zsh     : $(zsh --version 2>&1 || echo 'not found')"
echo "  xclip   : $(xclip -version 2>&1 | head -n1 || echo 'not found')"

if [ -x /usr/local/go/bin/go ]; then
    echo "  go      : $(/usr/local/go/bin/go version 2>&1)"
elif command -v go >/dev/null 2>&1; then
    echo "  go      : $(go version 2>&1)"
else
    echo "  go      : not found"
fi

if command -v claude >/dev/null 2>&1; then
    echo "  claude  : $(claude --version 2>&1 | head -n1)"
elif [ -x "${HOME}/.local/bin/claude" ]; then
    echo "  claude  : installed (open a new shell session to use 'claude')"
else
    echo "  claude  : not found"
fi

echo
if [ "${#STATUS_FAIL[@]}" -eq 0 ]; then
    log "All steps completed successfully. Start a new terminal session (or run 'source ~/.zshrc') to pick up zsh, Go, and Claude Code on your PATH."
    exit 0
else
    warn "Some steps failed — see the report above. Re-run this script after addressing them, or fix manually."
    exit 1
fi
