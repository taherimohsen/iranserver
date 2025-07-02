#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# تنظیمات پایه
PROTOCOLS=("SSH" "Vless" "Vmess" "OpenVPN")
DEFAULT_PORTS=("4234" "41369" "41374" "42347")
ALGORITHMS=("source" "roundrobin" "roundrobin" "source")
STICKY_TIMEOUTS=("4h" "0" "0" "8h")

# تابع بررسی دسترسی root
check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ Please run as root${NC}"
    exit 1
  fi
}

# تابع بررسی نسخه اوبونتو
check_ubuntu_version() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" = "ubuntu" ]; then
      if [ "$(echo "$VERSION_ID" | cut -d'.' -f1)" -lt 22 ]; then
        echo -e "${RED}❌ This script requires Ubuntu 22.04 or higher${NC}"
        exit 1
      fi
    else
      echo -e "${YELLOW}⚠️ This script is optimized for Ubuntu, but may work on other Debian-based systems${NC}"
    fi
  else
    echo -e "${YELLOW}⚠️ Could not detect OS version, continuing anyway...${NC}"
  fi
}

# تابع اعتبارسنجی پورت
validate_port() {
  local port=$1
  if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
    echo -e "${RED}❌ Invalid port number! Must be between 1024 and 65535${NC}"
    return 1
  fi
  return 0
}

# تابع نصب HAProxy
install_haproxy() {
  if ! command -v haproxy &> /dev/null; then
    echo -e "\n${YELLOW}🔧 Installing HAProxy...${NC}"
    apt update &> /dev/null
    apt install -y haproxy &> /dev/null
    
    # برای پشتیبانی از UDP در HAProxy نسخه 2.4+
    if ! haproxy -v | grep -q "2.4"; then
      echo -e "${YELLOW}⚠️ Upgrading HAProxy to version 2.4+ for UDP support${NC}"
      add-apt-repository -y ppa:vbernat/haproxy-2.4 &> /dev/null
      apt update &> /dev/null
      apt install -y haproxy=2.4.* &> /dev/null
    fi
  else
    echo -e "${GREEN}✅ HAProxy is already installed${NC}"
  fi
}

# تابع نصب پیش‌نیازها
install_deps() {
  echo -e "\n${YELLOW}🔧 Installing dependencies...${NC}"
  apt update &> /dev/null
  apt install -y ufw netcat-openbsd dnsutils &> /dev/null
}

# تابع پیکربندی پروتکل‌ها
configure_protocols() {
  declare -A CONFIG
  for i in "${!PROTOCOLS[@]}"; do
    echo -e "\n${YELLOW}🔘 ${PROTOCOLS[i]} Configuration${NC}"
    read -p "Enable ${PROTOCOLS[i]}? (y/n) [y]: " enabled
    enabled=${enabled:-y}
    
    if [[ "$enabled" =~ ^[Yy] ]]; then
      while true; do
        read -p "Port for ${PROTOCOLS[i]} [${DEFAULT_PORTS[i]}]: " port
        port=${port:-${DEFAULT_PORTS[i]}}
        if validate_port "$port"; then
          break
        fi
      done
      
      if [ "${PROTOCOLS[i]}" == "OpenVPN" ]; then
        echo -e "${YELLOW}🔘 OpenVPN Protocol Selection${NC}"
        echo "1) TCP (Recommended for stability)"
        echo "2) UDP (Better performance)"
        while true; do
          read -p "Choose protocol [1-2] (default:1): " proto_choice
          proto_choice=${proto_choice:-1}
          case $proto_choice in
            1) proto="tcp"; break ;;
            2) proto="udp"; break ;;
            *) echo -e "${RED}❌ Invalid choice! Please enter 1 or 2${NC}" ;;
          esac
        done
      else
        proto="tcp"
      fi
      
      CONFIG["${PROTOCOLS[i]},enabled"]=1
      CONFIG["${PROTOCOLS[i]},port"]=$port
      CONFIG["${PROTOCOLS[i]},proto"]=$proto
    else
      CONFIG["${PROTOCOLS[i]},enabled"]=0
    fi
  done
}

# تابع تولید کانفیگ HAProxy
generate_haproxy_config() {
  local backend_ips=("$@")
  
  cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0 info
    maxconn 10000
    tune.ssl.default-dh-param 2048
    stats socket /run/haproxy/admin.sock mode 660 level admin
    daemon

defaults
    log global
    mode tcp
    option tcplog
    option dontlognull
    timeout connect 5s
    timeout client 1h
    timeout server 1h
    retries 3
EOF

  # تولید کانفیگ برای هر پروتکل فعال
  for i in "${!PROTOCOLS[@]}"; do
    if [ "${CONFIG["${PROTOCOLS[i]},enabled"]}" -eq 1 ]; then
      port=${CONFIG["${PROTOCOLS[i]},port"]}
      proto=${CONFIG["${PROTOCOLS[i]},proto"]}
      algo=${ALGORITHMS[i]}
      sticky=${STICKY_TIMEOUTS[i]}

      cat >> /etc/haproxy/haproxy.cfg <<EOF

frontend ${PROTOCOLS[i],,}_front
    bind *:${port} ${proto}
    mode ${proto}
    default_backend ${PROTOCOLS[i],,}_back

backend ${PROTOCOLS[i],,}_back
    mode ${proto}
    balance ${algo}
EOF

      # تنظیمات پایداری جلسه برای پروتکل‌های مورد نیاز
      if [ "$sticky" != "0" ]; then
        cat >> /etc/haproxy/haproxy.cfg <<EOF
    stick-table type ip size 200k expire ${sticky}
    stick on src
EOF
      fi

      # تنظیمات خاص OpenVPN
      if [ "${PROTOCOLS[i]}" == "OpenVPN" ]; then
        cat >> /etc/haproxy/haproxy.cfg <<EOF
    option tcpka
    timeout tunnel 86400s
EOF
      fi

      # اضافه کردن سرورهای backend
      for ip in "${backend_ips[@]}"; do
        echo "    server ${PROTOCOLS[i],,}_${ip//./_} ${ip}:${port} check inter 10s" >> /etc/haproxy/haproxy.cfg
      done
    fi
  done
}

# تابع پیکربندی سرور ایران
configure_iran() {
  echo -e "\n${GREEN}🔵 Configuring IRAN Server (Load Balancer)${NC}"
  
  # دریافت لیست سرورهای خارجی
  echo -e "\n${YELLOW}🌐 Backend Server Configuration${NC}"
  echo "Enter backend servers (IP or domain, comma separated)"
  echo "Example: 1.1.1.1,2.2.2.2 or vpn1.example.com,vpn2.example.com"
  while true; do
    read -p "Backend servers: " backend_input
    if [ -z "$backend_input" ]; then
      echo -e "${RED}❌ Backend servers cannot be empty!${NC}"
      continue
    fi
    
    IFS=',' read -ra SERVER_LIST <<< "$backend_input"
    BACKEND_IPS=()
    
    for server in "${SERVER_LIST[@]}"; do
      if [[ $server =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        BACKEND_IPS+=("$server")
      else
        resolved_ips=($(dig +short "$server" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'))
        if [ ${#resolved_ips[@]} -eq 0 ]; then
          echo -e "${RED}❌ Could not resolve: $server${NC}"
        else
          BACKEND_IPS+=("${resolved_ips[@]}")
        fi
      fi
    done

    if [ ${#BACKEND_IPS[@]} -eq 0 ]; then
      echo -e "${RED}❌ No valid backend servers found! Please try again.${NC}"
    else
      break
    fi
  done

  echo -e "\n${GREEN}✅ Detected Backend Servers:${NC}"
  printf '%s\n' "${BACKEND_IPS[@]}"

  # تولید فایل کانفیگ HAProxy
  generate_haproxy_config "${BACKEND_IPS[@]}"

  # فعال‌سازی فایروال
  for i in "${!PROTOCOLS[@]}"; do
    if [ "${CONFIG["${PROTOCOLS[i]},enabled"]}" -eq 1 ]; then
      port=${CONFIG["${PROTOCOLS[i]},port"]}
      proto=${CONFIG["${PROTOCOLS[i]},proto"]}
      ufw allow "$port/${proto}"
    fi
  done
  
  ufw --force enable

  # تنظیم سرویس ریست خودکار
  cat > /etc/systemd/system/haproxy-reset.service <<EOF
[Unit]
Description=HAProxy Reset Service
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart haproxy

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/haproxy-reset.timer <<EOF
[Unit]
Description=HAProxy Auto Reset

[Timer]
OnBootSec=6h
OnUnitActiveSec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable haproxy-reset.timer haproxy
  systemctl start haproxy-reset.timer haproxy

  echo -e "\n${GREEN}✅ IRAN Server configured successfully!${NC}"
}

# تابع اصلی
main() {
  clear
  echo -e "${GREEN}🚀 Ultimate HAProxy Tunnel Manager${NC}"
  echo -e "${GREEN}================================${NC}"
  
  check_root
  check_ubuntu_version
  install_haproxy
  install_deps
  configure_protocols
  configure_iran

  echo -e "\n${GREEN}🎉 Configuration completed successfully!${NC}"
  echo -e "\n${YELLOW}📢 Important Notes:${NC}"
  echo "1. For OpenVPN, make sure your backend servers are configured with:"
  echo "   - 'proto tcp-server' or 'proto udp' matching your selection"
  echo "   - The same port number you configured here (${CONFIG["OpenVPN,port"]})"
  echo "2. System will auto-reset every 6 hours for stability"
  echo "3. Check HAProxy status with: systemctl status haproxy"
  echo -e "\n${GREEN}🚀 Happy tunneling!${NC}"
}

main
