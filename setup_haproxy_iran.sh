#!/bin/bash

clear
echo "🚀 HAProxy Advanced Tunnel Manager"
echo "================================"

# Correct port assignments
PORTS=("4234" "41369" "41374" "42347")
PROTOCOLS=("SSH" "Vless" "Vmess" "OpenVPN")
SERVICES=("ssh" "vless" "vmess" "openvpn")

# Function to check port status
check_port() {
  nc -zvw3 $1 $2 &>/dev/null
  if [ $? -eq 0 ]; then
    echo -e "[🟢] $1:$2"
    return 0
  else
    echo -e "[🔴] $1:$2"
    return 1
  fi
}

# Function to validate IP list
validate_ips() {
  local ip_list=$1
  for ip in $ip_list; do
    if ! [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "❌ Invalid IP detected: $ip"
      return 1
    fi
  done
  return 0
}

# Main menu
echo "1️⃣ IRAN Server (Load Balancer)"
echo "2️⃣ Kharej Server (Backend)"
read -p "Select server type [1/2]: " SERVER_TYPE

# Install required packages
apt update && apt install -y haproxy ufw netcat dnsutils

if [ "$SERVER_TYPE" == "1" ]; then
  # IRAN Server Configuration
  echo -e "\n🔵 IRAN Server Mode (Load Balancer)"
  
  # Get Kharej IPs
  IP_LIST=$(dig +short ssh.vipconfig.ir | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
  if ! validate_ips "$IP_LIST"; then
    exit 1
  fi
  
  echo -e "\n🔎 Checking Kharej servers status..."
  for ip in $IP_LIST; do
    echo -e "\n📡 Checking $ip:"
    for port in "${PORTS[@]}"; do
      check_port $ip $port
    done
  done

  # Protocol selection
  echo -e "\n🔘 Select protocols to enable (comma separated):"
  for i in "${!PORTS[@]}"; do
    echo "$((i+1))) ${PROTOCOLS[i]} (${PORTS[i]})"
  done
  echo "$(( ${#PORTS[@]} + 1 ))) All protocols"
  read -p "Enter choices (e.g. 1,3): " PROTOCOL_CHOICES

  # Process selections
  SELECTED_PORTS=()
  if [[ $PROTOCOL_CHOICES == *$(( ${#PORTS[@]} + 1 ))* ]]; then
    SELECTED_PORTS=("${PORTS[@]}")
  else
    IFS=',' read -ra CHOICES <<< "$PROTOCOL_CHOICES"
    for choice in "${CHOICES[@]}"; do
      index=$((choice-1))
      [ $index -ge 0 ] && [ $index -lt ${#PORTS[@]} ] && SELECTED_PORTS+=("${PORTS[index]}")
    done
  fi

  # Generate HAProxy config
  cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak
  cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    maxconn 10000
    daemon

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 5s
    timeout client 1m
    timeout server 1m
EOF

  # Add selected frontends and backends
  for port in "${SELECTED_PORTS[@]}"; do
    for i in "${!PORTS[@]}"; do
      if [ "${PORTS[i]}" == "$port" ]; then
        proto=${PROTOCOLS[i]}
        service=${SERVICES[i]}
        break
      fi
    done
    
    cat >> /etc/haproxy/haproxy.cfg <<EOF

frontend ${proto}_front
    bind *:$port
    default_backend ${proto}_back

backend ${proto}_back
    mode tcp
    balance leastconn
    option tcp-check
    tcp-check connect port $port
    default-server inter 2s fall 2 rise 1 check
EOF

    for ip in $IP_LIST; do
      if check_port $ip $port; then
        echo "    server ${proto}_$(echo $ip | tr '.' '_') $ip:$port check" >> /etc/haproxy/haproxy.cfg
      fi
    done
    
    ufw allow $port/tcp
    echo "✅ ${proto} (${port}) enabled"
  done

else
  # Kharej Server Configuration
  echo -e "\n🔵 Kharej Server Mode (Backend)"
  
  # Protocol selection
  echo -e "\n🔘 Select installed protocols (comma separated):"
  for i in "${!PORTS[@]}"; do
    echo "$((i+1))) ${PROTOCOLS[i]} (${PORTS[i]})"
  done
  read -p "Enter choices (e.g. 1,3): " PROTOCOL_CHOICES

  # Process selections
  SELECTED_PORTS=()
  IFS=',' read -ra CHOICES <<< "$PROTOCOL_CHOICES"
  for choice in "${CHOICES[@]}"; do
    index=$((choice-1))
    [ $index -ge 0 ] && [ $index -lt ${#PORTS[@]} ] && SELECTED_PORTS+=("${PORTS[index]}")
  done

  # Generate HAProxy config
  cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak
  cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    maxconn 10000
    daemon

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 5s
    timeout client 1m
    timeout server 1m
EOF

  # Add selected frontends and backends
  for port in "${SELECTED_PORTS[@]}"; do
    for i in "${!PORTS[@]}"; do
      if [ "${PORTS[i]}" == "$port" ]; then
        proto=${PROTOCOLS[i]}
        service=${SERVICES[i]}
        break
      fi
    done
    
    cat >> /etc/haproxy/haproxy.cfg <<EOF

frontend ${proto}_front
    bind *:$port
    default_backend ${proto}_back

backend ${proto}_back
    server local_${service} 127.0.0.1:$port
EOF
    
    ufw allow $port/tcp
    echo "✅ ${proto} (${port}) → Local service"
  done
fi

# Restart services
systemctl restart haproxy
systemctl enable haproxy
ufw --force enable

echo -e "\n🎉 Tunnel configuration completed!"
echo "🔍 Check status with: systemctl status haproxy"
