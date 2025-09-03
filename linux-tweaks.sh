#!/bin/bash

# Enhanced host setup script
# - SSH hardening
# - .bashrc improvements
# - Batch package installation
# - Custom MOTD with figlet

set -euo pipefail

# ────────────────────────────────
# Function to prompt user confirmation
confirm() {
    while true; do
        read -rp "👉 $1 [y/N]: " response
        case "$response" in
            [yY][eE][sS]|[yY]) return 0 ;;
            [nN][oO]|[nN]|"") return 1 ;;
            *) echo "❌ Invalid input. Please enter 'y' or 'n'." ;;
        esac
    done
}

# ────────────────────────────────
# Configure user SSH keys
GITHUB_UN="nikolaos83" # Set your Github Username accordingly
echo -e "\033[1;33m🔒 Setting up root user SSH config...\033[0m"
mkdir -p /root/.ssh
chmod 700 /root/.ssh
curl -fsSL "https://github.com/${GITHUB_UN}.keys" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# Disable root password authentication
echo "🔐 Checking SSH security settings..."
SSH_CONFIG="/etc/ssh/sshd_config"
SSH_CONFIG_DIR="/etc/ssh/sshd_config.d"

if confirm "Do you want to disable root password authentication?"; then
    echo "🔒 Disabling root password authentication..."
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSH_CONFIG"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG"
    if [ -d "$SSH_CONFIG_DIR" ]; then
        for conf in "$SSH_CONFIG_DIR"/*.conf; do
            [ -f "$conf" ] && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "$conf"
            [ -f "$conf" ] && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$conf"
        done
    fi
    systemctl restart sshd
    echo "✅ Root password authentication disabled!"
else
    echo "⚠️ Skipping SSH security modifications."
fi

# ────────────────────────────────
# Configure .bashrc
echo -e "\033[1;33m🎨 Configuring .bashrc...\033[0m"

cat <<'EOF' >> /root/.bashrc

# If this is an xterm, set the title and prompt
case "$TERM" in
    xterm*|rxvt*|xterm-256color)
        PROMPT_COMMAND='echo -ne "\033]0;$(printf "%s" "${debian_chroot:+($debian_chroot)}$USER@${HOSTNAME}: ${PWD}")\a"'
        ;;
esac

# Custom PS1 prompt
PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
EOF

# Enable color prompt + extend history
sed -i 's/^#force_color_prompt=yes/force_color_prompt=yes/' /root/.bashrc
sed -i 's/HISTSIZE=.*/HISTSIZE=5000/' /root/.bashrc
sed -i 's/HISTFILESIZE=.*/HISTFILESIZE=10000/' /root/.bashrc
echo "✅ .bashrc configured!"

# ────────────────────────────────
# Collect packages
NETWORK_UTILITIES="wget curl net-tools"
MONITORING_TOOLS="htop iotop sysstat iftop nethogs"
BENCHMARK_TOOLS="sysbench speedtest-cli fio hdparm"
FILE_TOOLS="tree unzip p7zip"

ALL_PKGS=""

if confirm "Do you want to install network utilities? ($NETWORK_UTILITIES)"; then
    ALL_PKGS+=" $NETWORK_UTILITIES"
fi
if confirm "Do you want to install monitoring tools? ($MONITORING_TOOLS)"; then
    ALL_PKGS+=" $MONITORING_TOOLS"
fi
if confirm "Do you want to install file management tools? ($FILE_TOOLS)"; then
    ALL_PKGS+=" $FILE_TOOLS"
fi
if confirm "Do you want to install benchmarking utilities? ($BENCHMARK_TOOLS)"; then
    ALL_PKGS+=" $BENCHMARK_TOOLS"
fi

# Always include figlet and curl for MOTD
ALL_PKGS+=" figlet curl"

# Run package installation once
if [ -n "$ALL_PKGS" ]; then
    echo "📦 Installing selected packages: $ALL_PKGS"
    apt update
    apt install -y $ALL_PKGS
    echo "✅ Packages installed!"
else
    echo "⚠️ No packages selected."
fi

# ────────────────────────────────
# Configure MOTD
echo "🛠️ Configuring MOTD..."
read -rp "Enter a custom MOTD message (default: ${HOSTNAME}): " motd_message
motd_message=${motd_message:-${HOSTNAME}}

mkdir -p /usr/share/figlet
curl -fsSL "https://raw.githubusercontent.com/xero/figlet-fonts/master/ANSI%20Shadow.flf" \
    -o /usr/share/figlet/Shadow.flf

cat >/etc/profile.d/motd.sh <<EOF
#!/bin/bash
echo -e "\033[1;33m\n"
figlet -f /usr/share/figlet/Shadow.flf "$motd_message"
echo -e "\033[0m"
EOF
chmod +x /etc/profile.d/motd.sh

echo "🎉 Host configuration complete!"
