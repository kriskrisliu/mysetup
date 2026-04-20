#!/usr/bin/env bash
set -euo pipefail

PROXY_URL="${PROXY_URL:-http://localhost:7890}"
export http_proxy="$PROXY_URL"
export https_proxy="$PROXY_URL"
export HTTP_PROXY="$PROXY_URL"
export HTTPS_PROXY="$PROXY_URL"
MINICONDA_URL="https://mirror.nju.edu.cn/anaconda/miniconda/Miniconda3-latest-Linux-x86_64.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
AUTHORIZED_KEYS_FILE="$SCRIPT_DIR/authorized_keys"
ZSHRC="$HOME/.zshrc"
MISSING_PACKAGES=()

log() {
    printf '==> %s\n' "$1"
}

warn() {
    printf 'Warning: %s\n' "$1"
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Error: %s is required but not installed.\n' "$1"
        exit 1
    fi
}

append_line_if_missing() {
    local line="$1"
    local file="$2"

    touch "$file"
    if ! grep -qxF "$line" "$file"; then
        printf '%s\n' "$line" >> "$file"
    fi
}

show_privilege_notice() {
    log "Using proxy: $PROXY_URL"
    if [ "$(id -u)" -eq 0 ]; then
        log "Running as root; missing dependencies will be installed directly"
    else
        log "If required dependencies are missing, the script will pause and ask whether to install them with sudo"
        log "Changing the default shell does not use sudo, but chsh may ask for your login password"
    fi
}

collect_missing_packages() {
    MISSING_PACKAGES=()

    command -v curl >/dev/null 2>&1 || MISSING_PACKAGES+=(curl)
    command -v git >/dev/null 2>&1 || MISSING_PACKAGES+=(git)
    command -v zsh >/dev/null 2>&1 || MISSING_PACKAGES+=(zsh)
    command -v nano >/dev/null 2>&1 || MISSING_PACKAGES+=(nano)
    command -v python3 >/dev/null 2>&1 || MISSING_PACKAGES+=(python3)
    [ -f /etc/ssl/certs/ca-certificates.crt ] || MISSING_PACKAGES+=(ca-certificates)
}

install_missing_packages() {
    collect_missing_packages

    if [ ${#MISSING_PACKAGES[@]} -eq 0 ]; then
        log "Required dependencies already installed"
        return
    fi

    log "Missing dependencies: ${MISSING_PACKAGES[*]}"

    if [ "$(id -u)" -eq 0 ]; then
        apt update
        apt install -y "${MISSING_PACKAGES[@]}"
        return
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        printf 'Error: missing dependencies require sudo apt install: %s\n' "${MISSING_PACKAGES[*]}"
        exit 1
    fi

    if [ ! -t 0 ]; then
        printf 'Error: missing dependencies require sudo apt install: %s\n' "${MISSING_PACKAGES[*]}"
        printf 'Please install them first or rerun the script interactively.\n'
        exit 1
    fi

    read -r -p "Install missing dependencies with sudo apt now? [y/N] " reply
    case "$reply" in
        [yY]|[yY][eE][sS])
            sudo apt update
            sudo apt install -y "${MISSING_PACKAGES[@]}"
            ;;
        *)
            printf 'Skipped dependency installation. Missing: %s\n' "${MISSING_PACKAGES[*]}"
            exit 1
            ;;
    esac
}

write_ssh_key() {
    log "Configuring SSH authorized_keys"

    if [ ! -f "$AUTHORIZED_KEYS_FILE" ]; then
        printf 'Error: authorized keys file not found: %s\n' "$AUTHORIZED_KEYS_FILE"
        exit 1
    fi

    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    touch "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"

    while IFS= read -r key || [ -n "$key" ]; do
        if [ -z "$key" ]; then
            continue
        fi

        if grep -qxF "$key" "$HOME/.ssh/authorized_keys"; then
            continue
        fi

        printf '%s\n' "$key" >> "$HOME/.ssh/authorized_keys"
    done < "$AUTHORIZED_KEYS_FILE"

    log "SSH public keys synced from $AUTHORIZED_KEYS_FILE"
}

ensure_oh_my_zsh_zshrc() {
    touch "$ZSHRC"
    append_line_if_missing 'export ZSH="$HOME/.oh-my-zsh"' "$ZSHRC"
    append_line_if_missing 'ZSH_THEME="robbyrussell"' "$ZSHRC"

    if grep -Eq '^plugins=\(' "$ZSHRC"; then
        if grep -Eq '^plugins=\([^)]*zsh-autosuggestions' "$ZSHRC"; then
            log "zsh-autosuggestions already enabled in .zshrc"
        else
            python3 - "$ZSHRC" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
new_text, count = re.subn(
    r'^plugins=\(([^)]*)\)$',
    lambda m: f"plugins=({m.group(1).strip()} zsh-autosuggestions)" if m.group(1).strip() else "plugins=(zsh-autosuggestions)",
    text,
    count=1,
    flags=re.M,
)
if count:
    path.write_text(new_text)
PY
            log "Enabled zsh-autosuggestions in .zshrc"
        fi
    else
        append_line_if_missing 'plugins=(git zsh-autosuggestions)' "$ZSHRC"
        log "Added plugins line to .zshrc"
    fi

    append_line_if_missing 'source $ZSH/oh-my-zsh.sh' "$ZSHRC"
}

install_oh_my_zsh() {
    log "Installing oh-my-zsh"
    export RUNZSH=no
    export CHSH=no

    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    else
        log "oh-my-zsh already installed"
    fi

    ensure_oh_my_zsh_zshrc
}

install_zsh_autosuggestions() {
    log "Installing zsh-autosuggestions"
    local zsh_custom_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
    local plugin_dir="$zsh_custom_dir/plugins/zsh-autosuggestions"

    mkdir -p "$zsh_custom_dir/plugins"
    if [ ! -d "$plugin_dir" ]; then
        git clone https://github.com/zsh-users/zsh-autosuggestions "$plugin_dir"
    else
        log "zsh-autosuggestions already installed"
    fi

    ensure_oh_my_zsh_zshrc
}

find_conda_base() {
    if [ -x "$HOME/miniconda3/bin/conda" ]; then
        printf '%s\n' "$HOME/miniconda3"
        return 0
    fi

    if command -v conda >/dev/null 2>&1; then
        local conda_bin
        conda_bin="$(command -v conda)"
        case "$conda_bin" in
            "$HOME"/*)
                dirname "$(dirname "$conda_bin")"
                return 0
                ;;
        esac
    fi

    return 1
}

install_miniconda() {
    local conda_base
    if conda_base="$(find_conda_base)"; then
        log "Miniconda already installed at $conda_base"
    else
        conda_base="$HOME/miniconda3"
        local installer
        installer="$(mktemp /tmp/miniconda.XXXXXX.sh)"
        log "Downloading Miniconda"
        curl -fsSL "$MINICONDA_URL" -o "$installer"
        log "Installing Miniconda to $conda_base"
        bash "$installer" -b -p "$conda_base"
        rm -f "$installer"
    fi

    log "Initializing conda for zsh"
    "$conda_base/bin/conda" init zsh >/dev/null 2>&1 || true
}

ensure_claude_path() {
    touch "$ZSHRC"
    append_line_if_missing 'export PATH="$HOME/.local/bin:$PATH"' "$ZSHRC"
    log "Ensured Claude Code PATH in .zshrc"
}

install_claude_code() {
    if command -v claude >/dev/null 2>&1; then
        log "Claude Code already installed"
    else
        log "Installing Claude Code"
        curl -fsSL https://claude.ai/install.sh | bash
    fi

    ensure_claude_path
}

install_global_skills() {
    local repo_skills_dir="$SCRIPT_DIR/.claude/skills"
    local global_skills_dir="$HOME/.claude/skills"

    if [ ! -d "$repo_skills_dir" ]; then
        log "No repository skills found, skipping global skill install"
        return
    fi

    mkdir -p "$global_skills_dir"
    rm -rf "$global_skills_dir"/* "$global_skills_dir"/.[!.]* "$global_skills_dir"/..?* 2>/dev/null || true
    cp -R "$repo_skills_dir"/. "$global_skills_dir"/
    log "Repository skills copied to $global_skills_dir with overwrite"
}

set_default_shell() {
    local zsh_path
    local current_shell
    zsh_path="$(command -v zsh)"
    current_shell="$(getent passwd "$USER" | cut -d: -f7 || printf '%s' "${SHELL:-}")"

    if [ "$current_shell" = "$zsh_path" ]; then
        log "Default shell is already zsh"
        return
    fi

    if [ "$(id -u)" -eq 0 ]; then
        log "Setting zsh as default shell for $USER"
        chsh -s "$zsh_path" "$USER" || warn "Failed to change default shell"
        return
    fi

    if [ ! -t 0 ]; then
        warn "Skipping default shell change in non-interactive mode; run this manually later: chsh -s $zsh_path"
        return
    fi

    read -r -p "Change default shell to zsh now? This may ask for your login password. [y/N] " reply
    case "$reply" in
        [yY]|[yY][eE][sS])
            chsh -s "$zsh_path" || warn "Failed to change default shell"
            ;;
        *)
            log "Skipped default shell change; run this manually later: chsh -s $zsh_path"
            ;;
    esac
}

main() {
    show_privilege_notice
    install_missing_packages
    require_command curl
    require_command git
    require_command python3
    require_command zsh

    write_ssh_key
    install_miniconda
    install_oh_my_zsh
    install_zsh_autosuggestions
    install_claude_code
    install_global_skills
    set_default_shell

    log "Done"
    printf 'You may run: source %s\n' "$ZSHRC"
}

main "$@"
