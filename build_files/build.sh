#!/bin/bash

set -ouex pipefail

### Install DE and other core packages
# Install Plasma Wayland and LXQt
dnf groupinstall -y "LXQt Desktop" \
  && dnf install -y network-manager-applet plasma-workspace-wayland labwc wayvnc greetd \
  && dnf clean all


### Install server packages
# Wayland-first server tools
dnf5 install -y tmux openssh-server nginx nodejs npm python3 python3-pip gcc gcc-c++ make initial-setup-gui anaconda-widgets

#### Example for enabling a System Unit File
systemctl enable podman.socket sshd

# Download noVNC (HTML5 VNC client)
mkdir -p /var/local || true
cd /var/local
rm -rf noVNC websockify
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

# Common installs
rpm-ostree install podman podman-compose tailscale cockpit-system cockpit-ostree cockpit-podman cockpit-storaged nginx bind-utils procps-ng jq

# Direct firewall rules
cat << EOF > /etc/firewalld/direct.xml
<direct>
  <zone>public</zone>
  <service port="22" protocol="tcp">ssh</service>
  <service port="9090" protocol="https">cockpit</service>
  <service port="6080" protocol="tcp">novnc</service>
  <service port="80" protocol="tcp">http</service>
</direct>
EOF

# Unified KWin-based Wayland VNC Server
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
    # Start the full Plasma session components
    QT_QPA_PLATFORM=wayland /usr/bin/startplasma-wayland &
else
    # Start the full LXQt session components
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

# Greetd Configuration
mkdir -p /etc/greetd
cat << 'EOF' > /etc/greetd/config.toml
[default_session]
command = "agreety --cmd /usr/bin/nasy-session-launcher"
user = "greeter"

[initial_session]
command = "/usr/bin/nasy-session-launcher"
user = "root"
EOF

# Session Launcher for Greetd (Pure Wayland via KWin)
cat << 'EOF' > /usr/bin/nasy-session-launcher
#!/bin/bash
source /etc/switch-session.conf
if [[ "$SESSION" == "plasma" ]]; then
    export PLASMA_SHELL_PACKAGE=org.kde.plasma.bigscreen
    exec startplasma-wayland
else
    # Use KWin as the compositor for LXQt
    exec kwin_wayland --xwayland --lxqt lxqt-session
fi
EOF
chmod +x /usr/bin/nasy-session-launcher

# Tailscale repo
cat << EOF > /etc/yum.repos.d/tailscale.repo
[tailscale]
name=Tailscale stable
baseurl=https://pkgs.tailscale.com/stable/fedora/\$basearch
enabled=1
type=rpm
repo_gpgcheck=1
gpgcheck=1
gpgkey=https://pkgs.tailscale.com/stable/fedora/repo.gpg
EOF

# Install NAS-Dashboard
mkdir -p /var/opt/nas-dashboard
git clone https://github.com/sounddrill31/NAS-Dashboard.git /tmp/nas-dashboard
cd /tmp/nas-dashboard
python3 install.py
rm -rf /tmp/nas-dashboard

# Tailscale auto-auth
mkdir -p /etc/systemd/system/tailscaled.service.d
cat << 'EOF' > /etc/systemd/system/tailscaled.service.d/authkey.conf
[Service]
ExecStartPost=/usr/bin/tailscale up --authkey=YOUR_AUTH_KEY --accept-routes
EOF

# Nginx config
mkdir -p /etc/nginx/conf.d
cat << 'EOF' > /etc/nginx/conf.d/dashboard.conf
server {
  listen 80;
  location / {
    proxy_pass http://localhost:8000;
    proxy_set_header Host $host;
  }
  location /cockpit { return 301 https://$host:9090$request_uri; }
  location /novnc/ {
    proxy_pass http://localhost:6080/;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
  }
}
EOF

# Enable services
systemctl enable nginx novnc vncserver nas-dashboard initial-setup greetd

# Configure initial-setup
mkdir -p /etc/initial-setup
echo "gui" > /etc/initial-setup/reconfig

# Install custom Anaconda Add-on
mkdir -p /usr/share/anaconda/addons
cp -r /ctx/build_files/nasy-addon/* /usr/share/anaconda/addons/

# Install custom binaries
cp /ctx/bin/* /usr/bin/
chmod +x /usr/bin/switch-session /usr/bin/set-hostname /usr/bin/nasy-switch-gui

# Install desktop entries
cp /ctx/bin/*.desktop /usr/share/applications/

# Initialize session config
echo "SESSION=lxqt" > /etc/switch-session.conf

# Set hostname
if [ -f /ctx/build_files/hostname ]; then
    IMAGE_HOSTNAME=$(cat /ctx/build_files/hostname)
    echo "$IMAGE_HOSTNAME" > /etc/hostname
fi
