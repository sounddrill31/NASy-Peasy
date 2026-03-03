#!/bin/bash

set -ouex pipefail

### Install packages
dnf5 install -y tmux openssh-server nginx nodejs npm python3 python3-pip gcc gcc-c++ make tigervnc-server

#### Example for enabling a System Unit File
systemctl enable podman.socket sshd

# Download noVNC (HTML5 VNC client)
mkdir -p /opt
cd /opt
rm -rf noVNC websockify
git clone https://github.com/novnc/noVNC.git
git clone https://github.com/novnc/websockify.git
ln -s /opt/noVNC/vnc.html /opt/noVNC/index.html

# noVNC systemd service (standalone proxy)
cat << 'EOF' > /etc/systemd/system/novnc.service
[Unit]
Description=noVNC proxy
After=network.target vncserver.service

[Service]
ExecStart=/opt/websockify/run 6080 localhost:5901 --web=/opt/noVNC
Restart=always
User=nobody

[Install]
WantedBy=multi-user.target
EOF

# Common installs
rpm-ostree install tailscale cockpit-system cockpit-ostree cockpit-podman nginx bind-utils procps-ng fcgiwrap jq

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

# Clean dashboard + CGI scripts
mkdir -p /usr/share/services/cgi-bin /etc/nginx/conf.d /etc/systemd/system/tailscaled.service.d

# Dashboard HTML (noVNC version)
cat << 'EOF' > /usr/share/services/index.html
<!doctype html>
<meta charset="utf-8">
<link rel="stylesheet" href="https://unpkg.com/mvp.css@1.12/mvp.css">
<title>🚀 Services Dashboard</title>
<body>
  <header>
    <h1>🖥️ Services Dashboard</h1>
    <p>🌐 Public IP: <span id="public-ip">Loading...</span></p>
    <p>🔌 Local IP: <span id="local-ip">-</span></p>
  </header>
  <main>
    <section>
      <h2>📊 Service Status & Controls</h2>
      <div id="services"></div>
    </section>
    <section>
      <h2>🔗 Quick Links</h2>
      <ul>
        <li><a href="https://localhost:9090" target="_blank">🛩️ Cockpit</a></li>
        <li><a href="http://localhost:6080/vnc.html" target="_blank">🖥️ noVNC</a></li>
        <li><a href="http://localhost:80" target="_blank">📊 Dashboard</a></li>
      </ul>
    </section>
    <details><summary>🔗 Proxies</summary>
      <ul>
        <li><a href="/cockpit" target="_blank">Cockpit</a></li>
        <li><a href="/novnc" target="_blank">noVNC</a></li>
      </ul>
    </details>
  </main>
  <script>
    const services = {cockpit: 'cockpit.socket', novnc: 'novnc.service', nginx: 'nginx.service', sshd: 'sshd.service', tailscaled: 'tailscaled.service'};
    fetch('/cgi-bin/public-ip').then(r=>r.text()).then(ip=>document.getElementById('public-ip').innerText=ip);
    document.getElementById('local-ip').innerText = window.location.hostname;
    async function refreshServices(){const status=await fetch('/cgi-bin/services').then(r=>r.json());document.getElementById('services').innerHTML=Object.entries(services).map(([n,u])=>{const a=status[u]||'unknown';const c=a==='active'?'green':a==='inactive'?'red':'gray';return`<details><summary>${n} <span style="color:${c}">● ${a}</span></summary><button onclick="control('${u}','start')">▶</button><button onclick="control('${u}','stop')">⏹</button><button onclick="control('${u}','restart')">🔄</button><button onclick="refreshServices()">↻</button></details>`;}).join('');}refreshServices();setInterval(refreshServices,5000);async function control(u,a){await fetch(`/cgi-bin/control?unit=${u}&action=${a}`);refreshServices();}
  </script>
</body>
EOF

# CGI scripts (updated for noVNC)
cat << 'EOF' > /usr/share/services/cgi-bin/public-ip
#!/bin/bash
echo "Content-Type: text/plain"
echo
dig +short myip.opendns.com @resolver1.opendns.com
EOF

cat << 'EOF' > /usr/share/services/cgi-bin/services
#!/bin/bash
echo "Content-Type: application/json"
echo '{"cockpit":"'$(systemctl is-active cockpit.socket 2>/dev/null || echo unknown)'","novnc":"'$(systemctl is-active novnc.service 2>/dev/null || echo unknown)'","nginx":"'$(systemctl is-active nginx.service 2>/dev/null || echo unknown)'","sshd":"'$(systemctl is-active sshd.service 2>/dev/null || echo unknown)'","tailscaled":"'$(systemctl --user is-active tailscaled.service 2>/dev/null || echo unknown)'"}'
EOF

cat << 'EOF' > /usr/share/services/cgi-bin/control
#!/bin/bash
echo "Content-Type: text/plain"
echo
read GET
unit=$(echo "$GET" | grep -o 'unit=[^&]*' | cut -d= -f2)
action=$(echo "$GET" | grep -o 'action=[^&]*' | cut -d= -f2)
if [[ "$unit" == "tailscaled.service" ]]; then
  su -c "systemctl --user $action tailscaled" $(whoami)
  [[ "$action" == "start" || "$action" == "restart" ]] && su -c "tailscale up --authkey=YOUR_AUTH_KEY --accept-routes" $(whoami)
else
  sudo systemctl $action $unit
fi
echo "OK"
EOF

chmod +x /usr/share/services/cgi-bin/*

# Tailscale auto-auth
cat << 'EOF' > /etc/systemd/system/tailscaled.service.d/authkey.conf
[Service]
ExecStartPost=/usr/bin/tailscale up --authkey=YOUR_AUTH_KEY --accept-routes
EOF

# Nginx config
cat << 'EOF' > /etc/nginx/conf.d/dashboard.conf
server {
  listen 80;
  root /usr/share/services;
  index index.html;
  
  location /cgi-bin/ { 
    include fastcgi_params;
    fastcgi_pass unix:/run/fcgiwrap.socket;
    fastcgi_param SCRIPT_FILENAME /usr/share/services/cgi-bin$fastcgi_script_name;
  }
  location /cockpit { return 301 https://localhost:9090$request_uri; }
  location /novnc {
    proxy_pass http://localhost:6080;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
  }
}
EOF

# Enable services
systemctl enable nginx fcgiwrap.socket novnc vncserver
systemctl daemon-reload
