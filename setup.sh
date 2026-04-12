#!/usr/bin/env bash
set -e
export http_proxy=http://localhost:7890 && export https_proxy=http://localhost:7890
KEY='ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDObLUKOV4pbl9ILvShiDpcpxAai8aigfv5SA13CeDvuGmzZwCJVPIUGlV9SKurbI3MtKb4/Dk45Mm7BbEjvCaQfCrsXZEwAbv3uZBrVeFOfAkWnkmYLDad7fGUE3DQp++3e/D1mjZ6///L2eO/8sUaFNKob1h20vFE6LXMVjoUo317DL/d9Sfy+3gL6Air23c2js+kZaMMfcrBySMufLhBgCkqSuv1zapfuVUZjeFmVwlhgPBMb+51BeH9FaYXjTcbcwkICN8CJJHBFLoatj1gdVfrhxS2qiwtMkqDj+H4gEoNZ1G9PNiOagrbuimg3buJDz6ADpFd4n2yuwL5OHMrW4Saqc9tTYAi9BisAGzym5ndsNVuiB04OiWYcfvxWKPjQbd3cT0/M+LBhRCddNWw18+NYsnfyzwTQpJ7mJBsVpjTv4LGgAShybk2/uE9dLlb6ZWcDSpjXpUjc0M4T3fo/SA78hNugmVEOseA9kZemuMvRV5oaPumSzHRGsTdrUc= 86158@KrisLiu'

install_oh_my_zsh() {
    echo "==> Installing oh-my-zsh..."
    export RUNZSH=no
    export CHSH=no
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    else
        echo "==> oh-my-zsh already installed, skipping"
    fi
}

write_ssh_key() {
    echo "==> Creating ~/.ssh directory..."
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    touch "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"

    echo "==> Writing SSH public key to authorized_keys..."
    grep -qxF "$KEY" "$HOME/.ssh/authorized_keys" || echo "$KEY" >> "$HOME/.ssh/authorized_keys"
}

install_zsh_autosuggestions() {
    echo "==> Installing zsh-autosuggestions plugin..."
    ZSH_CUSTOM_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
    PLUGIN_DIR="$ZSH_CUSTOM_DIR/plugins/zsh-autosuggestions"

    mkdir -p "$ZSH_CUSTOM_DIR/plugins"
    if [ ! -d "$PLUGIN_DIR" ]; then
        git clone https://github.com/zsh-users/zsh-autosuggestions "$PLUGIN_DIR"
    else
        echo "==> zsh-autosuggestions already exists, skipping"
    fi

    ZSHRC="$HOME/.zshrc"
    echo "==> Enabling zsh-autosuggestions in ~/.zshrc..."

    if [ -f "$ZSHRC" ]; then
        if grep -q "plugins=.*zsh-autosuggestions" "$ZSHRC"; then
            echo "==> Plugin already enabled in .zshrc"
        else
            if grep -q "^plugins=" "$ZSHRC"; then
                sed -i '/^plugins=/ s/)/ zsh-autosuggestions)/' "$ZSHRC"
            else
                echo 'plugins=(git zsh-autosuggestions)' >> "$ZSHRC"
            fi
        fi
    else
        cat > "$ZSHRC" <<'EOF'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git zsh-autosuggestions)
source $ZSH/oh-my-zsh.sh
EOF
    fi
}

if [ "$(id -u)" -eq 0 ]; then
    echo "==> Running as root: full setup"

    echo "==> Updating apt..."
    apt update

    echo "==> Installing zsh, nano, curl, git..."
    apt install -y zsh nano curl git

    if command -v conda >/dev/null 2>&1; then
        echo "==> Initializing conda for zsh..."
        conda init zsh || true
    else
        echo "==> conda not found, skipping conda init zsh"
    fi

    install_oh_my_zsh
    write_ssh_key
    install_zsh_autosuggestions

    echo "==> Setting zsh as default shell..."
    chsh -s "$(command -v zsh)" root || true

else
    echo "==> Running as non-root: limited setup only"
    echo "==> Will only install:"
    echo "    - oh-my-zsh"
    echo "    - zsh-autosuggestions"
    echo "    - SSH public key to authorized_keys"

    if ! command -v curl >/dev/null 2>&1; then
        echo "Error: curl is required but not installed."
        exit 1
    fi

    if ! command -v git >/dev/null 2>&1; then
        echo "Error: git is required but not installed."
        exit 1
    fi

    install_oh_my_zsh
    write_ssh_key
    install_zsh_autosuggestions
fi

echo "==> Done!"
echo "You may run: source ~/.zshrc"
