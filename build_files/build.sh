#!/bin/bash

set -ouex pipefail

### Install DE and other core packages
dnf groupinstall -y "LXQt Desktop" \
  && dnf install -y network-manager-applet \
  && dnf clean all


### Install server packages
dnf5 install -y tmux openssh-server nginx nodejs npm python3 python3-pip gcc gcc-c++ make tigervnc-server

#### Example for enabling a System Unit File
systemctl enable podman.socket sshd

# Download noVNC (HTML5 VNC client)
mkdir -p /var/local || true
cd /var/local
rm -rf noVNC websockify
git clone https://github.com/novnc/noVNC.git
git clone https://github.com/novnc/websockify.git
ln -s /var/local/noVNC/vnc.html /var/local/noVNC/index.html

# noVNC systemd service (standalone proxy)
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

# What about replacing firewall-cmd with direct firewalld config files?
rm -f /etc/firewalld/services/{ssh,cockpit,guac}.xml
cat << 'EOF' > /etc/firewalld/services/ssh.xml
<?xml version="1.0" encoding="utf-8"?>
<service version="1.0">
  <short>SSH</short>
  <description>Secure Shell protocol</description>
  <port protocol="tcp" port="22"/>
</service>
EOF

cat << 'EOF' > /etc/firewalld/services/cockpit.xml
<?xml version="1.0" encoding="utf-8"?>
<service version="1.0">
  <short>Cockpit</short>
  <description>Cockpit Web Service</description>
  <port protocol="https" port="9090"/>
</service>
EOF

cat << 'EOF' > /etc/firewalld/services/novnc.xml
<?xml version="1.0" encoding="utf-8"?>
<service version="1.0">
  <short>noVNC</short>
  <description>noVNC WebSocket proxy</description>
  <port protocol="tcp" port="6080"/>
</service>
EOF

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

# VNC Server systemd unit
cat << 'EOF' > /etc/systemd/system/vncserver.service
[Unit]
Description=Standalone VNC Server (Xvnc)
After=network.target

[Service]
Type=simple
# Runs Xvnc on display :1 (port 5901).
# Restricted to localhost with no password since noVNC proxies the connection.
ExecStart=/usr/bin/Xvnc :1 -localhost yes -geometry 1280x720 -depth 24 -SecurityTypes None -AlwaysShared
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

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
# Run the installer from the temporary directory
cd /tmp/nas-dashboard
python3 install.py

# Clean up temporary install files
rm -rf /tmp/nas-dashboard

# Tailscale auto-auth
mkdir -p /etc/systemd/system/tailscaled.service.d
cat << 'EOF' > /etc/systemd/system/tailscaled.service.d/authkey.conf
[Service]
ExecStartPost=/usr/bin/tailscale up --authkey=YOUR_AUTH_KEY --accept-routes
EOF

# Nginx config as reverse proxy
mkdir -p /etc/nginx/conf.d
cat << 'EOF' > /etc/nginx/conf.d/dashboard.conf
server {
  listen 80;
  
  location / {
    proxy_pass http://localhost:8000;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
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
systemctl enable nginx novnc vncserver nas-dashboard

