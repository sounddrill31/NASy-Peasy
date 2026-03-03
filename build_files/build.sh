#!/bin/bash

set -ouex pipefail

### Install packages

# Packages can be installed from any enabled yum repo on the image.
# RPMfusion repos are available by default in ublue main images
# List of rpmfusion packages can be found here:
# https://mirrors.rpmfusion.org/mirrorlist?path=free/fedora/updates/43/x86_64/repoview/index.html&protocol=https&redirect=1

# this installs a package from fedora repos
dnf5 install -y tmux openssh-server

# Use a COPR Example:
#
# dnf5 -y copr enable ublue-os/staging
# dnf5 -y install package
# Disable COPRs so they don't end up enabled on the final image:
# dnf5 -y copr disable ublue-os/staging

#### Example for enabling a System Unit File

systemctl enable podman.socket

# SSH setup
systemctl enable --now sshd
firewall-cmd --permanent --add-service=ssh

# Cockpit stuff
rpm-ostree install cockpit-system cockpit-ostree cockpit-podman
firewall-cmd --add-service=cockpit
firewall-cmd --add-service=cockpit --permanent

# Tailscale stuff
cat << EOF > /etc/yum.repos.d/tailscale.repo
[tailscale-stable]
name=Tailscale stable
baseurl=https://pkgs.tailscale.com/stable/fedora/\$basearch
enabled=1
type=rpm
repo_gpgcheck=1
gpgcheck=1
gpgkey=https://pkgs.tailscale.com/stable/fedora/repo.gpg
EOF
rpm-ostree install tailscale
systemctl --user enable tailscaled.service


# Guacamole guacd server
rpm-ostree install guacamole-server tomcat
systemctl enable guacd
firewall-cmd --permanent --add-port=4822/tcp
firewall-cmd --reload

# Basic Guacamole config setup (edit /etc/guacamole/guacamole.properties post-deploy for users/connections)
mkdir -p /etc/guacamole
cat << 'EOF' > /etc/guacamole/guacamole.properties
guacd-hostname: localhost
guacd-port:    4822
EOF
echo "export GUACAMOLE_HOME=/etc/guacamole" > /etc/profile.d/guacamole.sh

# Clean merged dashboard (dig IP + service controls + Tailscale auth)
rpm-ostree install nginx bind-utils procps-ng fcgiwrap jq
mkdir -p /usr/share/services/cgi-bin /etc/nginx/conf.d /etc/systemd/system/tailscaled.service.d

# Main dashboard HTML (merged features)
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
        <li><a href="http://localhost:8080/guacamole" target="_blank">🐊 Guacamole</a></li>
        <li><a href="http://localhost:80" target="_blank">📊 Dashboard</a></li>
      </ul>
    </section>

    <details>
      <summary>🔗 Proxies</summary>
      <ul>
        <li><a href="/cockpit" target="_blank">Cockpit Proxy</a></li>
        <li><a href="/guacamole" target="_blank">Guacamole Proxy</a></li>
      </ul>
    </details>
  </main>

  <script>
    const services = {
      cockpit: 'cockpit.socket',
      guacd: 'guacd.service', 
      tomcat: 'tomcat.service',
      nginx: 'nginx.service',
      sshd: 'sshd.service',
      tailscaled: 'tailscaled.service'
    };

    // Public IP via dig (server-side)
    fetch('/cgi-bin/public-ip')
      .then(r=>r.text()).then(ip=>document.getElementById('public-ip').innerText=ip);

    // Local IP from hostname
    document.getElementById('local-ip').innerText = window.location.hostname;

    // Service status + controls
    async function refreshServices() {
      const status = await fetch('/cgi-bin/services').then(r=>r.json());
      const container = document.getElementById('services');
      container.innerHTML = Object.entries(services).map(([name, unit]) => {
        const active = status[unit] || 'unknown';
        const color = active === 'active' ? 'green' : active === 'inactive' ? 'red' : 'gray';
        return `
          <details>
            <summary>${name} <span style="color:${color}">● ${active}</span></summary>
            <button onclick="control('${unit}', 'start')">▶ Start</button>
            <button onclick="control('${unit}', 'stop')">⏹ Stop</button>
            <button onclick="control('${unit}', 'restart')">🔄 Restart</button>
            <button onclick="refreshServices()">↻ Refresh</button>
          </details>
        `;
      }).join('');
    }
    refreshServices();
    setInterval(refreshServices, 5000);

    async function control(unit, action) {
      await fetch(`/cgi-bin/control?unit=${unit}&action=${action}`);
      refreshServices();
    }
  </script>
</body>
EOF

# CGI Scripts
cat << 'EOF' > /usr/share/services/cgi-bin/public-ip
#!/bin/bash
echo "Content-Type: text/plain"
echo
dig +short myip.opendns.com @resolver1.opendns.com
EOF

cat << 'EOF' > /usr/share/services/cgi-bin/services
#!/bin/bash
echo "Content-Type: application/json"
echo "{"
jq -n --argjson data "$(systemctl is-active cockpit.socket guacd.service tomcat.service nginx.service sshd.service tailscaled.service 2>/dev/null | paste -sd ',' - | jq -Rs)" '{cockpit: "\($data | split(",")[0])", guacd: "\($data | split(",")[1])", tomcat: "\($data | split(",")[2])", nginx: "\($data | split(",")[3])", sshd: "\($data | split(",")[4])", tailscaled: "\($data | split(",")[5])"}'
echo "}"
EOF

cat << 'EOF' > /usr/share/services/cgi-bin/control
#!/bin/bash
echo "Content-Type: text/plain"
echo
read GET
unit=$(echo "$GET" | grep -o 'unit=[^&]*' | cut -d= -f2)
action=$(echo "$GET" | grep -o 'action=[^&]*' | cut -d= -f2)

if [ "$unit" = "tailscaled.service" ] && [ "$action" = "start" ]; then
  sudo systemctl start tailscaled && sudo tailscale up --authkey=YOUR_AUTH_KEY --accept-routes
elif [ "$unit" = "tailscaled.service" ] && [ "$action" = "restart" ]; then
  sudo systemctl restart tailscaled && sleep 2 && sudo tailscale up --authkey=YOUR_AUTH_KEY --accept-routes
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
  location /guacamole { return 301 http://localhost:8080/guacamole$request_uri; }
}
EOF

firewall-cmd --permanent --add-service=http
systemctl enable nginx fcgiwrap.socket
systemctl daemon-reload
