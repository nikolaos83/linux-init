#!/bin/bash

# This script enhances system security, configures the shell environment, installs useful packages,
# and customizes the message of the day (MOTD) using figlet.

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

# Configure user SSH keys
GITHUB_UN="nikolaos83" # Set your Github Username accordingly
echo -e "\033[1;33m🔒 Setting up root user SSH config...\033[0m"
mkdir -p /root/.ssh
chmod 700 /root/.ssh
curl -fsSL "https://github.com/${GITHUB_UN}.keys" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# Disable root password authentication to enhance security
echo "🔐 Checking SSH security settings..."
SSH_CONFIG="/etc/ssh/sshd_config"
SSH_CONFIG_DIR="/etc/ssh/sshd_config.d"

if confirm "Do you want to disable root password authentication?"; then
    echo "🔒 Disabling root password authentication..."
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSH_CONFIG"
    sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' "$SSH_CONFIG"
    if [ -d "$SSH_CONFIG_DIR" ]; then
        for conf in "$SSH_CONFIG_DIR"/*.conf; do
            [ -f "$conf" ] && sed -i 's/^#PermitRootLogin.*/PermitRootLogin prohibit-password/' "$conf"
            [ -f "$conf" ] && sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' "$conf"
        done
    fi
    systemctl restart sshd  # Restart SSH service to apply changes
    echo "✅ Root password authentication disabled!"
else
    echo "⚠️ Skipping SSH security modifications."
fi

# Prompt user to configure terminal prompt
echo "🖥️ Configuring terminal prompt style..."
echo "Select a prompt style:"
echo "1) user@host:dir (default)"
echo "2) user@host"
echo "3) host:dir"
echo "4) host"
read -rp "Enter your choice [1-4]: " prompt_choice

# Assign prompt style based on choice
case "$prompt_choice" in
    2) PS1='\u@\h$ ';;
    3) PS1='\h:\w$ ';;
    4) PS1='\h$ ';;
    *) PS1='\u@\h:\w$ ';;
esac

# Configure .bashrc
echo -e "\033[1;33m🎨 Configuring .bashrc...\033[0m"

cat <<EOF >> /root/.bashrc

# If this is an xterm, set the title and prompt
case "\$TERM" in
    xterm*|rxvt*|xterm-256color)
        PROMPT_COMMAND='echo -ne "\033]0;$(printf "%s" "\${debian_chroot:+(\$debian_chroot)}\$USER@\${HOSTNAME}: \${PWD}")\a"'
        ;;
esac

# Apply user-chosen PS1 style
PS1='$PS1'
EOF

echo "✅ Terminal prompt style set!"

# Enable color prompt for better visibility
sed -i 's/^#force_color_prompt=yes/force_color_prompt=yes/' /root/.bashrc

# Increase shell history size for convenience
sed -i 's/HISTSIZE=.*/HISTSIZE=5000/' /root/.bashrc
sed -i 's/HISTFILESIZE=.*/HISTFILESIZE=10000/' /root/.bashrc

echo "✅ .bashrc configured!"

# Grouped package installation
NETWORK_UTILITIES="wget curl net-tools"
MONITORING_TOOLS="htop iotop sysstat iftop nethogs"
BENCHMARK_TOOLS="sysbench speedtest-cli fio hdparm"
FILE_TOOLS="tree unzip p7zip"

# Uncomment below to add candidates:
# CANDIDATE_PACKAGES="nmap iftop ncdu zsh vim"

echo "📦 Updating package lists..."
apt update

if confirm "Do you want to install network utilities? ($NETWORK_UTILITIES)"; then
    apt install -y $NETWORK_UTILITIES
    echo "✅ Network utilities installed!"
else
    echo "⚠️ Skipping network utilities."
fi

if confirm "Do you want to install monitoring tools? ($MONITORING_TOOLS)"; then
    apt install -y $MONITORING_TOOLS
    echo "✅ Monitoring tools installed!"
else
    echo "⚠️ Skipping monitoring tools."
fi
if confirm "Do you want to install file management tools? ($FILE_TOOLS)"; then
    apt install -y $FILE_TOOLS
    echo "✅ File management tools installed!"
else
    echo "⚠️ Skipping file management tools."
fi
if confirm "Do you want to install benchmarking utilities? ($BENCHMARK_TOOLS)"; then
    apt install -y $BENCHMARK_TOOLS
    echo "✅ Benchmarking utilities installed!"
else
    echo "⚠️ Skipping benchmarking utilities."
fi

# Prompt for MOTD message
echo "🛠️ Configuring MOTD..."
read -rp "Enter a custom MOTD message (default: ${HOSTNAME}): " motd_message
motd_message=${motd_message:-${HOSTNAME}}

# Install dependencies
apt install -y figlet curl

# Fetch figlet font
mkdir -p /usr/share/figlet
curl -fsSL "https://raw.githubusercontent.com/xero/figlet-fonts/master/ANSI%20Shadow.flf" -o /usr/share/figlet/Shadow.flf

# Detect if sudo exists and if we're running as root
if command -v sudo &>/dev/null; then
    SUDO="sudo"
elif [ "$EUID" -ne 0 ]; then
    echo "Error: You must run this script as root or have sudo installed." >&2
    exit 1
else
    SUDO=""
fi

# Create MOTD script
$SUDO tee /etc/profile.d/motd.sh >/dev/null <<EOF
echo -e "\033[1;33m\n"
figlet -f /usr/share/figlet/Shadow.flf "$motd_message"
echo -e "\033[0m"
EOF

# Make MOTD script executable
$SUDO chmod +x /etc/profile.d/motd.sh

# Done
echo "🎉 Host configuration complete!"
