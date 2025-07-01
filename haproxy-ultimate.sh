#!/bin/bash

# Basic settings
PROTOCOLS=("SSH" "Vless" "Vmess" "OpenVPN")
DEFAULT_PORTS=("4234" "41369" "41374" "42347")
ALGORITHMS=("source" "roundrobin" "roundrobin" "source")
STICKY_TIMEOUTS=("4h" "0" "0" "6h")  # Session persistence times

clear
echo "🚀 Ultimate HAProxy Tunnel Manager"
echo "================================"

# Server location selection
read -p "Is the server located in Iran? (y/n): " is_iran
if [ "$is_iran" = "y" ]; then
  echo "Applying optimized settings for Iran"
  SERVER_LOCATION="iran"
else
  echo "Applying settings for foreign servers"
  SERVER_LOCATION="foreign"
fi

# Protocol selection
echo "Please select required protocols:"
for i in "${!PROTOCOLS[@]}"; do
  read -p "Enable ${PROTOCOLS[i]} (port ${DEFAULT_PORTS[i]})? (y/n): " enable_proto
  if [ "$enable_proto" = "y" ]; then
    read -p "Custom port for ${PROTOCOLS[i]} (default ${DEFAULT_PORTS[i]}): " custom_port
    PORTS[i]=${custom_port:-${DEFAULT_PORTS[i]}}
    ENABLED_PROTOCOLS+=("${PROTOCOLS[i]}")
  else
    PORTS[i]=""
  fi
done

# Backend servers input
read -p "Enter backend server IPs (comma separated, leave empty for ssh.vipconfig.ir): " backend_servers
if [ -z "$backend_servers" ]; then
  if [ "$SERVER_LOCATION" = "iran" ]; then
    BACKEND_SERVERS=($(dig +short ssh.vipconfig.ir))
    echo "Using default Iranian servers: ${BACKEND_SERVERS[*]}"
  else
    echo "Error: For foreign servers you must enter server addresses"
    exit 1
  fi
else
  IFS=',' read -ra BACKEND_SERVERS <<< "$backend_servers"
fi

# Server health check function
check_server_health() {
  local ip=$1
  local port=$2
  nc -z -w 3 "$ip" "$port" &>/dev/null
  return $?
}

# Generate HAProxy config
generate_config() {
  cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0 info
    maxconn 10000
    tune.ssl.default-dh-param 2048
    daemon

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 5s
    timeout client 1h
    timeout server 1h
EOF

  for i in "${!PROTOCOLS[@]}"; do
    if [ -n "${PORTS[i]}" ]; then
      cat >> /etc/haproxy/haproxy.cfg <<EOF

frontend ${PROTOCOLS[i]}_front
    bind *:${PORTS[i]}
    default_backend ${PROTOCOLS[i]}_back

backend ${PROTOCOLS[i]}_back
    mode tcp
    balance ${ALGORITHMS[i]}
EOF

      # Session persistence for SSH and OpenVPN
      if [ "${STICKY_TIMEOUTS[i]}" != "0" ]; then
        cat >> /etc/haproxy/haproxy.cfg <<EOF
    stick-table type ip size 200k expire ${STICKY_TIMEOUTS[i]}
    stick on src
EOF
      fi

      # Add only active servers
      active_servers=0
      for ip in "${BACKEND_SERVERS[@]}"; do
        if check_server_health "$ip" "${PORTS[i]}"; then
          echo "    server ${PROTOCOLS[i]}_${ip//./_} $ip:${PORTS[i]} check" >> /etc/haproxy/haproxy.cfg
          active_servers=$((active_servers+1))
        else
          echo "    #server ${PROTOCOLS[i]}_${ip//./_} $ip:${PORTS[i]} check  # INACTIVE" >> /etc/haproxy/haproxy.cfg
        fi
      done
      
      # Add fallback server if no active servers found
      if [ $active_servers -eq 0 ]; then
        echo "    server ${PROTOCOLS[i]}_fallback 127.0.0.1:${PORTS[i]} backup" >> /etc/haproxy/haproxy.cfg
        echo "⚠️ Warning: No active servers found for ${PROTOCOLS[i]}, added fallback server"
      fi

      ufw allow "${PORTS[i]}"/tcp
    fi
  done
}

# Reset and health check function
reset_and_check() {
  echo "🔄 Resetting tunnels and checking servers..."

  # Clear sessions
  for proto in "${ENABLED_PROTOCOLS[@]}"; do
    if [[ "$proto" == "SSH" || "$proto" == "OpenVPN" ]]; then
      echo "clear table ${proto}_back" | socat /var/run/haproxy.sock stdio
    fi
  done

  # Check server health and update config
  for i in "${!PROTOCOLS[@]}"; do
    if [ -n "${PORTS[i]}" ]; then
      for ip in "${BACKEND_SERVERS[@]}"; do
        if ! check_server_health "$ip" "${PORTS[i]}"; then
          echo "🚨 Server ${PROTOCOLS[i]}_${ip//./_} is OFFLINE, disabling..."
          sed -i "/server ${PROTOCOLS[i]}_${ip//./_}/s/^/#/" /etc/haproxy/haproxy.cfg
        else
          echo "✅ Server ${PROTOCOLS[i]}_${ip//./_} is ONLINE"
          sed -i "/#server ${PROTOCOLS[i]}_${ip//./_}/s/^#//" /etc/haproxy/haproxy.cfg
        fi
      done
    fi
  done

  systemctl restart haproxy
}

# Setup automatic services
setup_services() {
  # 6-hour reset service
  cat > /etc/systemd/system/haproxy-reset.service <<EOF
[Unit]
Description=HAProxy Reset and Health Check
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '$(declare -f reset_and_check); reset_and_check'
EOF

  # 6-hour timer
  cat > /etc/systemd/system/haproxy-reset.timer <<EOF
[Unit]
Description=HAProxy Reset Timer

[Timer]
OnBootSec=6h
OnUnitActiveSec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF

  # Autostart service
  cat > /etc/systemd/system/haproxy-autostart.service <<EOF
[Unit]
Description=HAProxy Auto Start
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart haproxy

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable haproxy-reset.timer haproxy-autostart.service
  systemctl start haproxy-reset.timer
}

# Installation and setup
echo "Installing prerequisites..."
apt update && apt install -y haproxy ufw netcat dnsutils

echo "Generating configuration..."
generate_config

echo "Setting up automatic services..."
setup_services

systemctl restart haproxy
systemctl enable haproxy
ufw --force enable

echo -e "\n🎉 Configuration completed successfully!"
echo "📋 Active protocols:"
for i in "${!PROTOCOLS[@]}"; do
  if [ -n "${PORTS[i]}" ]; then
    echo "  ${PROTOCOLS[i]}:${PORTS[i]} | Algorithm:${ALGORITHMS[i]} | Sticky:${STICKY_TIMEOUTS[i]}"
  fi
done
echo -e "\n🔁 Auto-reset every 6 hours enabled"
echo "🔄 Auto-start after reboot enabled"