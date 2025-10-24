#!/bin/bash

###############################################################################
# Ubuntu Server Initial Setup Script
# Description: Automates initial server configuration after fresh installation
###############################################################################

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    print_error "Please run as root (use sudo)"
    exit 1
fi

print_status "Starting Ubuntu Server setup..."

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
# Create non-root sudo user (if needed)
###############################################################################
read -p "Create a non-root sudo user? (y/n): " create_user
if [ "$create_user" = "y" ]; then
    read -p "Enter username: " username
    adduser $username
    usermod -aG sudo $username
    print_status "User $username created with sudo privileges"
fi

###############################################################################
# 3. Configure Unattended Upgrades
###############################################################################
print_status "Installing and configuring unattended-upgrades..."
apt-get install -y unattended-upgrades

# Enable unattended upgrades
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

# Enable automatic updates
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

print_status "Unattended upgrades configured successfully"

###############################################################################
# 4. Configure Firewall (UFW)
###############################################################################
print_status "Configuring firewall..."

# Set default policies
ufw default deny incoming
ufw default allow outgoing

# Allow SSH (adjust port if needed)
ufw allow 22/tcp comment 'SSH'

# Allow HTTP/HTTPS if needed
# ufw allow 80/tcp comment 'HTTP'
# ufw allow 443/tcp comment 'HTTPS'

# Enable firewall
print_warning "Enabling firewall. Make sure SSH port is correct!"
yes | ufw enable

print_status "Firewall configured and enabled"

###############################################################################
# 5. Configure Fail2Ban
###############################################################################
print_status "Configuring Fail2Ban..."

# Create local jail configuration
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = 22
logpath = %(sshd_log)s
backend = systemd
EOF

# Enable and start fail2ban
systemctl enable fail2ban
systemctl restart fail2ban

print_status "Fail2Ban configured and started"

###############################################################################
# 6. Configure SSH (Basic Hardening)
###############################################################################
print_status "Basic SSH hardening..."

# Backup original sshd_config
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

#print_warning "Root SSH login is still ENABLED!"
# print_warning "Create a non-root user and disable root login manually later:"
# print_warning "  1. Create user: adduser USERNAME"
# print_warning "  2. Add sudo: usermod -aG sudo USERNAME"
# print_warning "  3. Edit /etc/ssh/sshd_config: PermitRootLogin no"
# print_warning "  4. Restart SSH: systemctl restart ssh"

# Apply basic SSH hardening
sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Restart SSH service
systemctl restart ssh

# print_warning "SSH hardening applied. Root login disabled."
# print_warning "Make sure you have a non-root user with sudo access!"

###############################################################################
# 7. Set Timezone (adjust as needed)
###############################################################################
print_status "Setting timezone to Europe/Berlin..."
timedatectl set-timezone Europe/Berlin

###############################################################################
# 8. Configure SMTP for Email Notifications (Optional)
###############################################################################
print_status "Installing msmtp for SMTP email notifications..."
apt-get install -y msmtp msmtp-mta

# Prompt for SMTP configuration
read -p "Configure SMTP for email notifications? (y/n): " configure_smtp
if [ "$configure_smtp" = "y" ]; then
    read -p "SMTP Host (e.g., smtp.gmail.com): " smtp_host
    
    # Ask for TLS/SSL configuration FIRST
    echo ""
    echo "TLS Configuration:"
    echo "1) STARTTLS (Port 587) - Standard für Gmail, etc."
    echo "2) SSL/TLS (Port 465) - Für Ionos, Strato, etc."
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
    
    read -p "SMTP Port (default: ${default_port}, press Enter to use default): " smtp_port
    smtp_port=${smtp_port:-$default_port}
    
    read -p "SMTP User/Email: " smtp_user
    read -s -p "SMTP Password: " smtp_pass
    echo ""
    read -p "From Email Address: " from_email
    read -p "Notification Email Address: " notify_email
    
    # Create msmtp configuration
    cat > /etc/msmtprc << EOF
# Default settings
defaults
auth           on
tls            ${tls_on}
tls_starttls   ${tls_starttls}
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

# SMTP Account
account        default
host           ${smtp_host}
port           ${smtp_port}
from           ${from_email}
user           ${smtp_user}
password       ${smtp_pass}
EOF

    # Set proper permissions
    chmod 600 /etc/msmtprc
    
    # Create log file with proper permissions
    touch /var/log/msmtp.log
    chown root:msmtp /var/log/msmtp.log 2>/dev/null || chown root:root /var/log/msmtp.log
    chmod 660 /var/log/msmtp.log
    
    # Configure unattended-upgrades to send email
    sed -i "s|//Unattended-Upgrade::Mail \"\";|Unattended-Upgrade::Mail \"${notify_email}\";|" /etc/apt/apt.conf.d/50unattended-upgrades
    sed -i 's|//Unattended-Upgrade::MailReport "on-change";|Unattended-Upgrade::MailReport "on-change";|' /etc/apt/apt.conf.d/50unattended-upgrades
    
    print_status "SMTP configured successfully"
    
    # Test email
    read -p "Send test email? (y/n): " send_test
    if [ "$send_test" = "y" ]; then
        echo "This is a test email from $(hostname)" | msmtp ${notify_email}
        print_status "Test email sent to ${notify_email}"
    fi
else
    print_warning "SMTP configuration skipped. Email notifications disabled."
fi

###############################################################################
# 9. Clean Up
###############################################################################
print_status "Cleaning up..."
apt-get autoremove -y
apt-get autoclean -y

###############################################################################
# 10. System Information
###############################################################################
print_status "======================================"
print_status "Setup completed successfully!"
print_status "======================================"
echo ""
print_status "System Information:"
echo "Hostname: $(hostname)"
echo "OS: $(lsb_release -d | cut -f2)"
echo "Kernel: $(uname -r)"
echo "Timezone: $(timedatectl | grep "Time zone" | awk '{print $3}')"
echo ""
print_status "Installed services status:"
systemctl is-active --quiet ufw && echo "UFW: Active" || echo "UFW: Inactive"
systemctl is-active --quiet fail2ban && echo "Fail2Ban: Active" || echo "Fail2Ban: Inactive"
systemctl is-active --quiet unattended-upgrades && echo "Unattended-Upgrades: Active" || echo "Unattended-Upgrades: Inactive"
echo ""
print_warning "Important notes:"
echo "1. Root SSH login has been disabled"
echo "2. Firewall is active - only SSH (port 22) is allowed"
echo "3. Automatic security updates are enabled"
echo "4. Fail2Ban is monitoring SSH attempts"
echo ""
print_status "Consider additional steps:"
echo "- Create a non-root sudo user if not already done"
echo "- Configure SSH key authentication and disable password auth"
echo "- Open additional firewall ports as needed (ufw allow PORT)"
echo "- Configure email/SMTP for update notifications"
echo ""
print_status "You may want to reboot the server: sudo reboot"
