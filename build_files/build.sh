#!/bin/bash

set -ouex pipefail

### 1. Install Desktop Environments & Packages
# Install LXQt Group using dnf5 syntax
dnf install -y @lxqt-desktop-environment

# Install Plasma Bigscreen, Plasma Login Manager, and Wayland tools
dnf install -y \
    plasma-bigscreen \
    plasma-workspace-wayland \
    plasma-login-manager \
    kcm-plasmalogin \
    glibc-langpack-en \
    network-manager-applet \
    labwc \
    wayvnc \
    python3-websockify \
    anaconda-widgets \
    tmux \
    openssh-server \
    nginx \
    nodejs \
    npm \
    python3 \
    python3-pip \
    gcc \
    gcc-c++ \
    make \
    jq \
    bind-utils \
    procps-ng

dnf clean all

# Configure Locale (Required for Qt6/Plasma)
echo "LANG=en_US.UTF-8" > /etc/locale.conf

### 2. Configure Display Manager (Plasma Login Manager)
# Disable other greeters and force PLM as the default
systemctl disable gdm greetd lightdm sddm || true
systemctl enable --force plasmalogin

# Configure Plasma Login Manager for autologin (will be set by switch-session or initial-setup)
mkdir -p /etc/plasmalogin.conf.d

# Create the custom LXQt-on-KWin Wayland session
mkdir -p /usr/share/wayland-sessions
cat << 'EOF' > /usr/share/wayland-sessions/nasy-lxqt.desktop
[Desktop Entry]
Name=NASy-Peasy Desktop (LXQt on Wayland)
Comment=LXQt Session using KWin Wayland
Exec=/usr/bin/kwin_wayland --xwayland --exit-with-session=/usr/bin/startlxqt
Type=Application
DesktopNames=LXQt
EOF

# Create a dedicated Plasma Bigscreen session that forces the Bigscreen shell
cat << 'EOF' > /usr/share/wayland-sessions/nasy-plasma-bigscreen.desktop
[Desktop Entry]
Name=NASy-Peasy Bigscreen (Plasma)
Comment=Plasma Wayland with Bigscreen Shell
Exec=env PLASMA_SHELL_PACKAGE=org.kde.plasma.bigscreen /usr/bin/startplasma-wayland
Type=Application
DesktopNames=KDE
EOF

systemctl set-default graphical.target
systemctl enable podman.socket sshd nginx

### 3. Professional Remote Desktop (Autostart wayvnc)
# Instead of a manual background service, we let the session start the VNC server.
# This ensures it shows exactly what the user sees on their "professional" PLM session.
mkdir -p /etc/xdg/autostart
cat << 'EOF' > /etc/xdg/autostart/nasy-vnc.desktop
[Desktop Entry]
Type=Application
Name=NASy-Peasy VNC Server
Exec=wayvnc 0.0.0.0 5901
Icon=network-server
Comment=Allow remote access to this session
X-GNOME-Autostart-enabled=true
OnlyShowIn=KDE;LXQt;
EOF

### 4. Dashboards and Other Tools
# Download noVNC
mkdir -p /var/local/novnc
git clone https://github.com/novnc/noVNC.git /var/local/novnc
ln -s /var/local/novnc/vnc.html /var/local/novnc/index.html

# Ensure the nobody user can access the web files and the parent directory
chown -R nobody:nobody /var/local/novnc
chmod 755 /var/local /var/local/novnc

# noVNC systemd service using system websockify
cat << 'EOF' > /etc/systemd/system/novnc.service
[Unit]
Description=noVNC proxy
After=network.target

[Service]
ExecStart=/usr/bin/websockify 6080 localhost:5901 --web=/var/local/novnc
Restart=always
User=nobody

[Install]
WantedBy=multi-user.target
EOF

# SELinux fixes for noVNC
# Allow websockify to bind to its port and serve files
semanage fcontext -a -t httpd_sys_content_t "/var/local/novnc(/.*)?" || true
restorecon -Rv /var/local/novnc || true

# Install NAS-Dashboard
mkdir -p /var/opt/nas-dashboard
git clone https://github.com/sounddrill31/NAS-Dashboard.git /tmp/nas-dashboard
cd /tmp/nas-dashboard
python3 install.py
rm -rf /tmp/nas-dashboard

# Configure Nginx as a unified reverse proxy
mkdir -p /etc/nginx/default.d
cat << 'EOF' > /etc/nginx/default.d/nasy-proxy.conf
# NAS-Dashboard (Main UI)
location / {
    proxy_pass http://localhost:8000;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}

# noVNC (Remote Desktop)
location /vnc/ {
    proxy_pass http://localhost:6080/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "Upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 61s;
    proxy_buffering off;
}
EOF

# SELinux fixes for Nginx proxying
# This boolean allows Nginx to connect to ANY backend port (8000, 6080, etc.)
setsebool -P httpd_can_network_connect 1 || true

# Label directories so Nginx can access them
semanage fcontext -a -t httpd_sys_content_t "/var/opt/nas-dashboard(/.*)?" || true
semanage fcontext -a -t httpd_sys_content_t "/var/local/novnc(/.*)?" || true
restorecon -Rv /var/opt/nas-dashboard /var/local/novnc || true

# Enable remaining services
systemctl enable novnc nas-dashboard

### 5. Custom Integrations
# Install custom NASy-Peasy Anaconda Addon (for ISO Installation)
# This will show the setup questions during the actual OS installation
mkdir -p /usr/share/anaconda/addons
cp -r /ctx/build_files/nasy-addon/* /usr/share/anaconda/addons/

# Install custom binaries and desktop entries
cp /ctx/bin/* /usr/bin/
chmod +x /usr/bin/switch-session /usr/bin/set-hostname /usr/bin/nasy-switch-gui
cp /ctx/bin/*.desktop /usr/share/applications/

# Initialize session config (defaults to LXQt)
/usr/bin/switch-session set lxqt

# Set hostname if specified in build context
if [ -f /ctx/build_files/hostname ]; then
    IMAGE_HOSTNAME=$(cat /ctx/build_files/hostname)
    echo "$IMAGE_HOSTNAME" > /etc/hostname
fi
