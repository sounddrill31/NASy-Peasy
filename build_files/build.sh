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
    zenity \
    initial-setup-gui \
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

# Configure Plasma Login Manager for autologin
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

systemctl set-default graphical.target
systemctl enable podman.socket sshd nginx initial-setup

### 3. Wayland VNC Server (Headless LabWC)
cat << 'EOF' > /usr/bin/nasy-vnc-server
#!/bin/bash
source /etc/switch-session.conf
export XDG_RUNTIME_DIR=/run/user/0
export WAYLAND_DISPLAY=wayland-vnc
mkdir -p $XDG_RUNTIME_DIR

# Start labwc as the headless compositor with wayvnc
labwc -s "wayvnc --render-node /dev/dri/renderD128 0.0.0.0 5901" &
COMPOSITOR_PID=$!

sleep 3

if [[ "$SESSION" == "plasma" ]]; then
    export PLASMA_SHELL_PACKAGE=org.kde.plasma.bigscreen
    QT_QPA_PLATFORM=wayland /usr/bin/startplasma-wayland &
else
    # Start LXQt components
    lxqt-session &
fi

wait $COMPOSITOR_PID
EOF
chmod +x /usr/bin/nasy-vnc-server

# VNC Server systemd unit
cat << 'EOF' > /etc/systemd/system/vncserver.service
[Unit]
Description=NASy-Peasy Wayland VNC Server (KWin)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/nasy-vnc-server
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

### 4. Dashboards and Other Tools
# Download noVNC
mkdir -p /var/local
cd /var/local
git clone https://github.com/novnc/noVNC.git
git clone https://github.com/novnc/websockify.git
ln -s /var/local/noVNC/vnc.html /var/local/noVNC/index.html

# noVNC systemd service
cat << 'EOF' > /etc/systemd/system/novnc.service
[Unit]
Description=noVNC proxy
After=network.target vncserver.service

[Service]
ExecStart=/var/local/websockify/run 6080 localhost:5901 --web=/var/local/noVNC
Restart=always
User=nobody

[Install]
WantedBy=multi-user.target
EOF

# Install NAS-Dashboard
mkdir -p /var/opt/nas-dashboard
git clone https://github.com/sounddrill31/NAS-Dashboard.git /tmp/nas-dashboard
cd /tmp/nas-dashboard
python3 install.py
rm -rf /tmp/nas-dashboard

# Configure Nginx as a reverse proxy for the dashboard
mkdir -p /etc/nginx/default.d
cat << 'EOF' > /etc/nginx/default.d/nas-dashboard.conf
location / {
    proxy_pass http://localhost:8000;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
EOF

# Enable remaining services
systemctl enable novnc vncserver nas-dashboard

### 5. Custom Integrations
# Configure initial-setup
mkdir -p /etc/initial-setup
echo "gui" > /etc/initial-setup/reconfig

# Install custom Anaconda Add-on
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
