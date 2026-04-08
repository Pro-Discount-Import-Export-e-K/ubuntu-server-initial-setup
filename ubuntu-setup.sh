#!/bin/bash

###############################################################################
# Ubuntu Server Initial Setup Script
# Description: Automates initial server configuration after fresh installation
#
# Safe ordering:
#   1. System update & packages
#   2. Create non-root user
#   3. Deploy SSH keys (paste or drop-folder)
#   4. Change SSH port to random 5XXXX
#   5. VERIFY new SSH connection works (user confirms in second terminal)
#   6. Only then: harden SSH (disable root, disable password auth)
#   7. Only then: enable firewall with the new SSH port allowed
###############################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
print_step()    { echo -e "\n${BLUE}==>${NC} ${BLUE}$1${NC}\n"; }

ask_yes_no() {
    # $1 = prompt, $2 = default (y|n)
    local prompt="$1"
    local default="$2"
    local hint="[y/N]"
    [ "$default" = "y" ] && hint="[Y/n]"
    local answer
    read -r -p "$prompt $hint: " answer
    answer=${answer:-$default}
    [[ "$answer" =~ ^[Yy]$ ]]
}

if [ "$EUID" -ne 0 ]; then
    print_error "Please run as root (use sudo)"
    exit 1
fi

print_status "Starting Ubuntu Server setup..."

###############################################################################
# 1. System Update
###############################################################################
print_step "1. System update"
apt-get update
apt-get upgrade -y
apt-get dist-upgrade -y

###############################################################################
# 2. Essential packages
###############################################################################
print_step "2. Installing essential packages"
apt-get install -y \
    curl wget git vim nano htop net-tools \
    software-properties-common apt-transport-https \
    ca-certificates gnupg lsb-release \
    ufw fail2ban

###############################################################################
# 3. Non-root sudo user
###############################################################################
print_step "3. Non-root sudo user"

TARGET_USER=""
if ask_yes_no "Create a non-root sudo user?" "y"; then
    read -r -p "Enter username: " TARGET_USER
    if id "$TARGET_USER" &>/dev/null; then
        print_warning "User $TARGET_USER already exists, skipping creation"
    else
        adduser "$TARGET_USER"
        usermod -aG sudo "$TARGET_USER"
        print_status "User $TARGET_USER created with sudo privileges"
    fi
else
    print_warning "No non-root user created. You will NOT be able to disable root login safely."
    read -r -p "Enter existing username to use for SSH key setup (or leave empty to use root): " TARGET_USER
fi

# Resolve home dir for the account that will receive SSH keys
if [ -n "$TARGET_USER" ]; then
    TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    TARGET_GROUP=$(id -gn "$TARGET_USER")
else
    TARGET_USER="root"
    TARGET_HOME="/root"
    TARGET_GROUP="root"
fi

###############################################################################
# 4. SSH key deployment
###############################################################################
print_step "4. SSH key deployment for user '$TARGET_USER'"

SSH_DIR="$TARGET_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"
KEY_DROP_DIR="/root/setup-ssh-keys"

mkdir -p "$SSH_DIR"
touch "$AUTH_KEYS"

echo "How do you want to add SSH public keys?"
echo "  1) Paste one or more keys now (one per line, empty line to finish)"
echo "  2) Drop .pub files into $KEY_DROP_DIR and have me import them"
echo "  3) Skip (not recommended — you'll stay on password auth)"
read -r -p "Select [1/2/3]: " key_method

case "$key_method" in
    1)
        echo "Paste public keys. Empty line finishes input:"
        while IFS= read -r line; do
            [ -z "$line" ] && break
            echo "$line" >> "$AUTH_KEYS"
            print_status "Added key: ${line:0:50}..."
        done
        ;;
    2)
        mkdir -p "$KEY_DROP_DIR"
        chmod 700 "$KEY_DROP_DIR"
        print_status "Drop folder: $KEY_DROP_DIR"
        print_warning "Copy your .pub files into $KEY_DROP_DIR now."
        print_warning "Example from your workstation:"
        echo "    scp ~/.ssh/id_ed25519.pub root@$(hostname -I | awk '{print $1}'):$KEY_DROP_DIR/"
        read -r -p "Press Enter when all keys are in place..."

        shopt -s nullglob
        key_files=("$KEY_DROP_DIR"/*.pub)
        shopt -u nullglob

        if [ ${#key_files[@]} -eq 0 ]; then
            print_warning "No .pub files found in $KEY_DROP_DIR — skipping"
        else
            for f in "${key_files[@]}"; do
                cat "$f" >> "$AUTH_KEYS"
                print_status "Imported: $(basename "$f")"
            done
        fi
        ;;
    *)
        print_warning "Skipping SSH key setup"
        ;;
esac

# Fix permissions + dedupe
if [ -s "$AUTH_KEYS" ]; then
    sort -u "$AUTH_KEYS" -o "$AUTH_KEYS"
fi
chmod 700 "$SSH_DIR"
chmod 600 "$AUTH_KEYS"
chown -R "$TARGET_USER:$TARGET_GROUP" "$SSH_DIR"

KEY_COUNT=$(wc -l < "$AUTH_KEYS" 2>/dev/null || echo 0)
print_status "authorized_keys now contains $KEY_COUNT key(s)"

###############################################################################
# 5. Random SSH port
###############################################################################
print_step "5. Changing SSH port"

# Pick a random unused port in 50000-59999
NEW_SSH_PORT=""
for _ in {1..20}; do
    CANDIDATE=$(shuf -i 50000-59999 -n 1)
    if ! ss -tlnH "sport = :$CANDIDATE" | grep -q .; then
        NEW_SSH_PORT=$CANDIDATE
        break
    fi
done

if [ -z "$NEW_SSH_PORT" ]; then
    print_error "Could not find a free port in 50000-59999"
    exit 1
fi

print_status "Selected SSH port: $NEW_SSH_PORT"

# Backup sshd_config once
cp -n /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# Drop-in config so we don't fight with existing Port lines
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-setup-port.conf << EOF
# Managed by ubuntu-setup.sh
Port $NEW_SSH_PORT
EOF

# Make sure a stray "Port 22" in the main file doesn't override us
sed -i 's/^\s*Port\s\+22\s*$/#Port 22/' /etc/ssh/sshd_config || true

systemctl restart ssh

###############################################################################
# 6. VERIFY new SSH connection (critical safety gate)
###############################################################################
print_step "6. Verify SSH works on new port"

SERVER_IP=$(hostname -I | awk '{print $1}')

cat <<EOF
${YELLOW}
============================================================
  STOP. Do not close this session.

  Open a SECOND terminal on your workstation and test:

    ssh -p $NEW_SSH_PORT $TARGET_USER@$SERVER_IP

  Verify:
    - You can log in
    - Key-based login works (no password prompt), if you added keys

  Only continue here after the second terminal works.
============================================================
${NC}
EOF

if ! ask_yes_no "Did the new SSH connection on port $NEW_SSH_PORT work?" "n"; then
    print_error "Aborting hardening. Your current session stays open."
    print_warning "SSH is now on port $NEW_SSH_PORT. Port 22 drop-in: /etc/ssh/sshd_config.d/10-setup-port.conf"
    print_warning "Firewall is NOT enabled, root login is NOT disabled. Fix SSH, then re-run."
    exit 1
fi

###############################################################################
# 7. SSH hardening (only after verified connection)
###############################################################################
print_step "7. SSH hardening"

HARDEN_ROOT="no"
HARDEN_PW="no"

if ask_yes_no "Disable root SSH login? (requires working non-root login)" "y"; then
    HARDEN_ROOT="yes"
fi

if [ "$KEY_COUNT" -gt 0 ]; then
    if ask_yes_no "Disable SSH password authentication? (key-only login)" "y"; then
        HARDEN_PW="yes"
    fi
else
    print_warning "No SSH keys deployed — keeping password auth enabled"
fi

cat > /etc/ssh/sshd_config.d/20-setup-hardening.conf << EOF
# Managed by ubuntu-setup.sh
PermitRootLogin $([ "$HARDEN_ROOT" = "yes" ] && echo "no" || echo "yes")
PasswordAuthentication $([ "$HARDEN_PW" = "yes" ] && echo "no" || echo "yes")
PubkeyAuthentication yes
EOF

# sshd -t validates config before we bounce the service
if ! sshd -t; then
    print_error "sshd config test failed — reverting hardening drop-in"
    rm -f /etc/ssh/sshd_config.d/20-setup-hardening.conf
    exit 1
fi

systemctl restart ssh
print_status "SSH hardened (root=$HARDEN_ROOT, password=$HARDEN_PW)"

###############################################################################
# 8. Fail2Ban
###############################################################################
print_step "8. Fail2Ban"

cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = $NEW_SSH_PORT
logpath = %(sshd_log)s
backend = systemd
EOF

systemctl enable fail2ban
systemctl restart fail2ban

###############################################################################
# 9. Firewall (opt-in, only after SSH is verified)
###############################################################################
print_step "9. Firewall (UFW)"

if ask_yes_no "Enable UFW firewall now? (default incoming=deny, outgoing=allow)" "n"; then
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "$NEW_SSH_PORT"/tcp comment 'SSH'

    if ask_yes_no "Also allow HTTP (80)?" "n";  then ufw allow 80/tcp  comment 'HTTP';  fi
    if ask_yes_no "Also allow HTTPS (443)?" "n"; then ufw allow 443/tcp comment 'HTTPS'; fi

    print_warning "Enabling firewall — SSH port $NEW_SSH_PORT is allowed"
    yes | ufw enable
    ufw status verbose
else
    print_warning "Firewall NOT enabled. Remember to configure it manually."
    print_warning "  ufw default deny incoming"
    print_warning "  ufw default allow outgoing"
    print_warning "  ufw allow $NEW_SSH_PORT/tcp"
    print_warning "  ufw enable"
fi

###############################################################################
# 10. Unattended upgrades
###############################################################################
print_step "10. Unattended upgrades"
apt-get install -y unattended-upgrades

cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

###############################################################################
# 11. Timezone
###############################################################################
print_step "11. Timezone"
timedatectl set-timezone Europe/Berlin

###############################################################################
# 12. SMTP (optional)
###############################################################################
print_step "12. SMTP (optional)"
apt-get install -y msmtp msmtp-mta

if ask_yes_no "Configure SMTP for email notifications?" "n"; then
    read -r -p "SMTP Host (e.g., smtp.gmail.com): " smtp_host

    echo ""
    echo "TLS Configuration:"
    echo "  1) STARTTLS (Port 587) - Gmail, etc."
    echo "  2) SSL/TLS  (Port 465) - Ionos, Strato, etc."
    read -r -p "Select TLS mode (1 or 2): " tls_mode

    if [ "$tls_mode" = "2" ]; then
        tls_on="on"; tls_starttls="off"; default_port="465"
    else
        tls_on="on"; tls_starttls="on"; default_port="587"
    fi

    read -r -p "SMTP Port (default: ${default_port}): " smtp_port
    smtp_port=${smtp_port:-$default_port}

    read -r -p "SMTP User/Email: " smtp_user
    read -r -s -p "SMTP Password: " smtp_pass
    echo ""
    read -r -p "From Email Address: " from_email
    read -r -p "Notification Email Address: " notify_email

    cat > /etc/msmtprc << EOF
defaults
auth           on
tls            ${tls_on}
tls_starttls   ${tls_starttls}
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        default
host           ${smtp_host}
port           ${smtp_port}
from           ${from_email}
user           ${smtp_user}
password       ${smtp_pass}
EOF

    chmod 600 /etc/msmtprc
    touch /var/log/msmtp.log
    chown root:msmtp /var/log/msmtp.log 2>/dev/null || chown root:root /var/log/msmtp.log
    chmod 660 /var/log/msmtp.log

    sed -i "s|//Unattended-Upgrade::Mail \"\";|Unattended-Upgrade::Mail \"${notify_email}\";|" /etc/apt/apt.conf.d/50unattended-upgrades
    sed -i 's|//Unattended-Upgrade::MailReport "on-change";|Unattended-Upgrade::MailReport "on-change";|' /etc/apt/apt.conf.d/50unattended-upgrades

    if ask_yes_no "Send test email?" "y"; then
        echo "This is a test email from $(hostname)" | msmtp "${notify_email}"
        print_status "Test email sent to ${notify_email}"
    fi
else
    print_warning "SMTP skipped"
fi

###############################################################################
# 13. Cleanup
###############################################################################
print_step "13. Cleanup"
apt-get autoremove -y
apt-get autoclean -y

# Remove the key drop folder if it's empty
if [ -d "$KEY_DROP_DIR" ] && [ -z "$(ls -A "$KEY_DROP_DIR" 2>/dev/null)" ]; then
    rmdir "$KEY_DROP_DIR"
fi

###############################################################################
# Summary
###############################################################################
echo ""
print_status "======================================"
print_status "Setup completed"
print_status "======================================"
echo ""
echo "Hostname : $(hostname)"
echo "OS       : $(lsb_release -d | cut -f2)"
echo "Kernel   : $(uname -r)"
echo "Timezone : $(timedatectl | grep "Time zone" | awk '{print $3}')"
echo ""
echo "SSH port : $NEW_SSH_PORT"
echo "SSH user : $TARGET_USER"
echo "Root SSH : $([ "$HARDEN_ROOT" = "yes" ] && echo "disabled" || echo "enabled")"
echo "Password : $([ "$HARDEN_PW" = "yes" ] && echo "disabled (key-only)" || echo "enabled")"
echo ""
systemctl is-active --quiet ufw                  && echo "UFW                 : active"   || echo "UFW                 : inactive"
systemctl is-active --quiet fail2ban             && echo "Fail2Ban            : active"   || echo "Fail2Ban            : inactive"
systemctl is-active --quiet unattended-upgrades  && echo "Unattended-Upgrades : active"   || echo "Unattended-Upgrades : inactive"
echo ""
print_warning "New SSH command: ssh -p $NEW_SSH_PORT $TARGET_USER@$SERVER_IP"
