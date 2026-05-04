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
Exec=/usr/bin/kwin_wayland --xwayland --lxqt lxqt-session
Type=Application
DesktopNames=LXQt
EOF

systemctl set-default graphical.target
systemctl enable podman.socket sshd nginx initial-setup

### 3. Wayland VNC Server (KWin-native)
cat << 'EOF' > /usr/bin/nasy-vnc-server
#!/bin/bash
source /etc/switch-session.conf
export XDG_RUNTIME_DIR=/run/user/0
export WAYLAND_DISPLAY=wayland-vnc
mkdir -p $XDG_RUNTIME_DIR

# Start headless KWin with built-in VNC
kwin_wayland --headless --vnc-port 5901 --socket $WAYLAND_DISPLAY --width 1280 --height 720 &
KWIN_PID=$!

sleep 3

if [[ "$SESSION" == "plasma" ]]; then
    export PLASMA_SHELL_PACKAGE=org.kde.plasma.bigscreen
    QT_QPA_PLATFORM=wayland /usr/bin/startplasma-wayland &
else
    # Start the full LXQt session components on KWin
    lxqt-session &
fi

wait $KWIN_PID
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
