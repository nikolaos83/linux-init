#!/bin/bash

# Setup Samba
echo -e "\033[1;33mConfiguring Samba...\033[0m"
cat > /etc/samba/smb.conf <<EOF
[global]
   workgroup = WORKGROUP
   server string = %h server (Samba, Ubuntu)
   security = user
   encrypt passwords = true
   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file
   panic action = /usr/share/samba/panic-action %d
   server role = standalone server
   passdb backend = tdbsam
   valid users = niko, root

[${HOSTNAME}_home]
   comment = Home folder on ${HOSTNAME}
   path = /home
   browseable = no
   read only = no
   guest ok = no
   smb encrypt = required
   valid users = niko, root

[${HOSTNAME}]
   comment = Root folder on ${HOSTNAME}
   path = /
   browseable = no
   read only = no
   guest ok = no
   smb encrypt = required
   valid users = niko, root
EOF

# Download Samba password backup file
GITHUB_UN="nikolaos83" # Set your Github Username accordingly
GITHUB_REPO="linux-init"
URL="https://raw.githubusercontent.com/${GITHUB_UN}/${GITHUB_REPO}/main/samba_pwd_backup.tdb" # Set your own URL here, or set GITHUB_UN and GITHUB_REPO accordingly
echo -e "\033[1;33mDownloading Samba password backup file...\033[0m"
curl -fsSL "$URL" -o /root/samba_pwd_backup.tdb

# Enable Samba
echo -e "\033[1;33m✅ Enabling Samba...\033[0m"

pdbedit -i tdbsam:/root/samba_pwd_backup.tdb

systemctl enable smbd
systemctl restart smbd

echo -e "\033[1;33m✅ Init Complete!\033[0m"
