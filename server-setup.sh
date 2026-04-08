#!/bin/bash

###############################################################################
# Ubuntu Server Initial Setup Script
# Description: Automates initial server configuration after fresh installation
###############################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}======================================${NC}"
}

if [ "$EUID" -ne 0 ]; then 
    print_error "Please run as root (use sudo)"
    exit 1
fi

print_header "Starting Ubuntu Server setup..."

###############################################################################
# 1. System Update
###############################################################################
print_status "Updating package lists..."
apt-get update

print_status "Upgrading installed packages..."
apt-get upgrade -y

print_status "Performing distribution upgrade..."
apt-get dist-upgrade -y

###############################################################################
# 2. Install Essential Packages
###############################################################################
print_status "Installing essential packages..."
apt-get install -y \
    curl \
    wget \
    git \
    vim \
    nano \
    htop \
    net-tools \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release \
    ufw \
    fail2ban

###############################################################################
# 3. Create sudo User FIRST (before any SSH hardening)
###############################################################################
print_header "User Setup"

while true; do
    read -p "Create a non-root sudo user? (y/n): " create_user
    if [ "$create_user" = "y" ]; then
        read -p "Enter username: " username
        
        if id "$username" &>/dev/null; then
            print_warning "User $username already exists"
            read -p "Use existing user? (y/n): " use_existing
            if [ "$use_existing" != "y" ]; then
                continue
            fi
        else
            adduser $username
            usermod -aG sudo $username
            print_status "User $username created with sudo privileges"
        fi
        
        # SSH Key Setup for user
        print_status "Setting up SSH key authentication..."
        mkdir -p /home/$username/.ssh
        chmod 700 /home/$username/.ssh
        
        read -p "Do you have an SSH public key to add? (y/n): " has_ssh_key
        if [ "$has_ssh_key" = "y" ]; then
            read -p "Paste your SSH public key (or press Enter to skip): " ssh_key
            if [ -n "$ssh_key" ]; then
                echo "$ssh_key" >> /home/$username/.ssh/authorized_keys
                chmod 600 /home/$username/.ssh/authorized_keys
                chown -R $username:$username /home/$username/.ssh
                print_status "SSH public key added for $username"
            fi
        else
            print_warning "No SSH key added. You can add it later to /home/$username/.ssh/authorized_keys"
        fi
        
        break
    elif [ "$create_user" = "n" ]; then
        print_warning "No sudo user created. SSH hardening will be skipped."
        username=""
        break
    fi
done

###############################################################################
# 4. Configure SSH Port (Random 5XXXX)
###############################################################################
print_header "SSH Configuration"

# Generate random port in 50000-59999 range
RANDOM_SSH_PORT=$((50000 + RANDOM % 10000))

read -p "Use random SSH port in 5XXXX range? (y/n, default: y): " use_random_port
if [ "$use_random_port" = "y" ] || [ -z "$use_random_port" ]; then
    ssh_port=$RANDOM_SSH_PORT
    print_status "Selected random SSH port: $ssh_port"
else
    read -p "Enter custom SSH port: " ssh_port
    ssh_port=${ssh_port:-22}
fi

# Backup and update sshd_config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# Change port
sed -i "s/^#Port 22/Port $ssh_port/" /etc/ssh/sshd_config
sed -i "s/^Port 22/Port $ssh_port/" /etc/ssh/sshd_config

print_warning "SSH port changed to $ssh_port"
print_warning "Root login remains ENABLED until you confirm access works!"
print_warning "Connect with: ssh -p $ssh_port $username@your-server-ip"

###############################################################################
# 5. Configure Firewall (UFW) - User Controlled
###############################################################################
print_header "Firewall Configuration (UFW)"

read -p "Configure firewall now? (y/n, recommended: n): " configure_ufw
if [ "$configure_ufw" = "y" ]; then
    read -p "Default incoming policy: (d)eny/(a)llow: " default_in
    read -p "Default outgoing policy: (d)eny/(a)llow: " default_out
    
    if [ "$default_in" = "d" ]; then
        ufw default deny incoming
    else
        ufw default allow incoming
    fi
    
    if [ "$default_out" = "d" ]; then
        ufw default deny outgoing
    else
        ufw default allow outgoing
    fi
    
    # Allow SSH on custom port
    ufw allow $ssh_port/tcp comment "SSH"
    
    read -p "Allow HTTP (80)? (y/n): " allow_http
    if [ "$allow_http" = "y" ]; then
        ufw allow 80/tcp comment 'HTTP'
    fi
    
    read -p "Allow HTTPS (443)? (y/n): " allow_https
    if [ "$allow_https" = "y" ]; then
        ufw allow 443/tcp comment 'HTTPS'
    fi
    
    print_warning "Enabling firewall..."
    yes | ufw enable
    print_status "Firewall enabled with custom rules"
else
    print_warning "Firewall configuration skipped. Configure manually later with: ufw enable"
fi

###############################################################################
# 6. Fail2Ban Configuration
###############################################################################
print_header "Fail2Ban Configuration"

read -p "Configure Fail2Ban? (y/n, default: y): " configure_fail2ban
if [ "$configure_fail2ban" = "y" ] || [ -z "$configure_fail2ban" ]; then
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = $ssh_port
logpath = %(sshd_log)s
backend = systemd
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban
    print_status "Fail2Ban configured and started (port $ssh_port)"
else
    print_warning "Fail2Ban skipped"
fi

###############################################################################
# 7. SSH Hardening - DISABLED BY DEFAULT
###############################################################################
print_header "SSH Security Hardening"

print_warning "=============================================="
print_warning "SSH HARDENING IS DISABLED BY DEFAULT"
print_warning "=============================================="
echo ""
echo "Current SSH settings (unchanged):"
echo "  - Port: $ssh_port"
echo "  - Root login: ENABLED (password auth)"
echo "  - Password auth: ENABLED"
echo ""
echo "After you confirm SSH access works ($username@server -p $ssh_port),"
echo "run the hardening script manually:"
echo "  sudo /usr/local/bin/ssh-hardening.sh $ssh_port $username"
echo ""

# Create hardening script for later use
cat > /usr/local/bin/ssh-hardening.sh << 'HARDENSCRIPT'
#!/bin/bash

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <ssh_port> <username>"
    echo "Example: $0 52345 myuser"
    exit 1
fi

SSH_PORT=$1
USERNAME=$2

echo "Applying SSH hardening..."

# Disable root login
sed -i 's/^PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config

# Enable key-only auth
sed -i 's/^#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# Disable password auth
sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config

# Disable empty passwords
sed -i 's/^#PermitEmptyPasswords yes/PermitEmptyPasswords no/' /etc/ssh/sshd_config
sed -i 's/^PermitEmptyPasswords yes/PermitEmptyPasswords no/' /etc/ssh/sshd_config

# Disable challenge-response auth
sed -i 's/^#ChallengeResponseAuthentication yes/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^ChallengeResponseAuthentication yes/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config

# Disable use PAM
sed -i 's/^#UsePAM yes/UsePAM no/' /etc/ssh/sshd_config
sed -i 's/^UsePAM yes/UsePAM no/' /etc/ssh/sshd_config

systemctl restart ssh

# Update UFW if needed
if command -v ufw &> /dev/null; then
    ufw delete allow 22/tcp 2>/dev/null || true
    ufw allow $SSH_PORT/tcp comment "SSH (hardened)"
fi

echo "SSH hardening applied!"
echo "  - Root login: DISABLED"
echo "  - Key-only auth: ENABLED"
echo "  - Password auth: DISABLED"
echo ""
echo "IMPORTANT: Test key-based login BEFORE logging out!"
HARDENSCRIPT

chmod +x /usr/local/bin/ssh-hardening.sh
print_status "Hardening script created at /usr/local/bin/ssh-hardening.sh"

###############################################################################
# 8. Unattended Upgrades
###############################################################################
print_header "Unattended Upgrades"

read -p "Configure automatic security updates? (y/n, default: y): " configure_auto_update
if [ "$configure_auto_update" = "y" ] || [ -z "$configure_auto_update" ]; then
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

    print_status "Unattended upgrades configured"
else
    print_warning "Auto-updates skipped"
fi

###############################################################################
# 9. Timezone
###############################################################################
print_status "Setting timezone to Europe/Berlin..."
timedatectl set-timezone Europe/Berlin

###############################################################################
# 10. SMTP (Optional)
###############################################################################
print_header "Email Notifications (SMTP)"

read -p "Configure SMTP for email notifications? (y/n): " configure_smtp
if [ "$configure_smtp" = "y" ]; then
    apt-get install -y msmtp msmtp-mta
    
    read -p "SMTP Host (e.g., smtp.gmail.com): " smtp_host
    
    echo "TLS Configuration:"
    echo "1) STARTTLS (Port 587)"
    echo "2) SSL/TLS (Port 465)"
    read -p "Select TLS mode (1 or 2): " tls_mode
    
    if [ "$tls_mode" = "2" ]; then
        tls_on="on"
        tls_starttls="off"
        default_port="465"
    else
        tls_on="on"
        tls_starttls="on"
        default_port="587"
    fi
    
    read -p "SMTP Port (default: ${default_port}): " smtp_port
    smtp_port=${smtp_port:-$default_port}
    
    read -p "SMTP User/Email: " smtp_user
    read -s -p "SMTP Password: " smtp_pass
    echo ""
    read -p "From Email Address: " from_email
    read -p "Notification Email Address: " notify_email
    
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
    chmod 660 /var/log/msmtp.log
    
    sed -i "s|//Unattended-Upgrade::Mail \"\"|Unattended-Upgrade::Mail \"${notify_email}\";|" /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null || true
    sed -i 's|//Unattended-Upgrade::MailReport "on-change"|Unattended-Upgrade::MailReport "on-change"|' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null || true
    
    print_status "SMTP configured"
    
    read -p "Send test email? (y/n): " send_test
    if [ "$send_test" = "y" ]; then
        echo "Test email from $(hostname)" | msmtp ${notify_email}
        print_status "Test email sent"
    fi
fi

###############################################################################
# 11. Cleanup
###############################################################################
print_status "Cleaning up..."
apt-get autoremove -y
apt-get autoclean -y

###############################################################################
# Final Summary
###############################################################################
print_header "Setup Complete!"

echo ""
echo "=============================================="
echo "IMPORTANT NEXT STEPS:"
echo "=============================================="
echo ""
if [ -n "$username" ]; then
    echo "1. TEST SSH ACCESS NOW:"
    echo "   ssh -p $ssh_port $username@YOUR_SERVER_IP"
    echo ""
    echo "2. If SSH works, RUN HARDENING:"
    echo "   sudo /usr/local/bin/ssh-hardening.sh $ssh_port $username"
    echo ""
    echo "3. Only then - log out and test root/key access"
    echo ""
else
    echo "1. No sudo user created - SSH hardening skipped"
    echo "2. Create a user and configure SSH manually"
fi
echo "=============================================="
echo ""
echo "System Info:"
echo "  Hostname: $(hostname)"
echo "  OS: $(lsb_release -d | cut -f2)"
echo "  Kernel: $(uname -r)"
echo "  Timezone: $(timedatectl | grep 'Time zone' | awk '{print $3}')"
echo "  SSH Port: $ssh_port"
echo ""

systemctl is-active --quiet ufw && echo "UFW: Active" || echo "UFW: Inactive"
systemctl is-active --quiet fail2ban && echo "Fail2Ban: Active" || echo "Fail2Ban: Inactive"
systemctl is-active --quiet unattended-upgrades && echo "Auto-updates: Active" || echo "Auto-updates: Inactive"

echo ""
print_warning "Reboot recommended: sudo reboot"
