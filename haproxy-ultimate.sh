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

# تابع نمایش هدر اسکریپت
show_header() {
  clear
  echo -e "${GREEN}"
  echo "   _    _    _    _    _    _    _    _    _    _  "
  echo "  / \  / \  / \  / \  / \  / \  / \  / \  / \  / \ "
  echo " ( H )( A )( P )( R )( O )( X )( Y )( T )( M )( G )"
  echo "  \_/  \_/  \_/  \_/  \_/  \_/  \_/  \_/  \_/  \_/ "
  echo -e "${NC}"
  echo -e "${GREEN}🚀 Ultimate HAProxy Tunnel Manager - Stable Version${NC}"
  echo -e "${GREEN}===============================================${NC}"
  echo -e "${YELLOW}📅 Created: $(date)${NC}"
  echo -e "${YELLOW}🖥️  OS: $(lsb_release -d | cut -f2-)${NC}"
  echo -e "${YELLOW}🌐 IP: $(curl -s ifconfig.me)${NC}\n"
}

# تابع بررسی دسترسی root
check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}❌ Error: This script must be run as root${NC}"
    exit 1
  fi
}

# تابع بررسی نسخه اوبونتو
check_ubuntu_version() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" = "ubuntu" ]; then
      if [ "$(echo "$VERSION_ID" | cut -d'.' -f1)" -lt 22 ]; then
        echo -e "${RED}❌ Error: This script requires Ubuntu 22.04 or higher${NC}"
        exit 1
      fi
    else
      echo -e "${YELLOW}⚠️ Warning: This script is optimized for Ubuntu, but may work on other Debian-based systems${NC}"
      sleep 2
    fi
  else
    echo -e "${YELLOW}⚠️ Warning: Could not detect OS version, continuing anyway...${NC}"
    sleep 2
  fi
}

# تابع اعتبارسنجی پورت
validate_port() {
  local port=$1
  if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
    echo -e "${RED}❌ Error: Invalid port number! Must be between 1024 and 65535${NC}"
    return 1
  fi
  
  # بررسی اینکه پورت قبلا استفاده نشده باشد
  if ss -tuln | grep -q ":$port "; then
    echo -e "${RED}❌ Error: Port $port is already in use${NC}"
    return 1
  fi
  
  return 0
}

# تابع نصب HAProxy
install_haproxy() {
  if ! command -v haproxy &> /dev/null; then
    echo -e "\n${YELLOW}🔧 Installing HAProxy...${NC}"
    apt-get update > /dev/null 2>&1
    apt-get install -y haproxy > /dev/null 2>&1
    
    # برای پشتیبانی از UDP در HAProxy نسخه 2.4+
    if ! haproxy -v | grep -q "2.4"; then
      echo -e "${YELLOW}⚠️ Upgrading HAProxy to version 2.4+ for UDP support${NC}"
      add-apt-repository -y ppa:vbernat/haproxy-2.4 > /dev/null 2>&1
      apt-get update > /dev/null 2>&1
      apt-get install -y haproxy=2.4.* > /dev/null 2>&1
    fi
    
    echo -e "${GREEN}✅ HAProxy installed successfully${NC}"
  else
    echo -e "${GREEN}✅ HAProxy is already installed (Version: $(haproxy -v | head -n1))${NC}"
  fi
}

# تابع نصب پیش‌نیازها
install_deps() {
  echo -e "\n${YELLOW}🔧 Installing dependencies...${NC}"
  apt-get update > /dev/null 2>&1
  apt-get install -y ufw netcat-openbsd dnsutils curl > /dev/null 2>&1
  echo -e "${GREEN}✅ Dependencies installed successfully${NC}"
}

# تابع پیکربندی پروتکل‌ها
configure_protocols() {
  declare -A CONFIG
  for i in "${!PROTOCOLS[@]}"; do
    echo -e "\n${YELLOW}🔘 ${PROTOCOLS[i]} Configuration${NC}"
    
    # فعال کردن پروتکل
    while true; do
      read -p "Enable ${PROTOCOLS[i]}? (y/n) [y]: " enabled
      enabled=${enabled:-y}
      if [[ "$enabled" =~ ^[YyNn]$ ]]; then
        break
      fi
      echo -e "${RED}❌ Invalid input! Please enter y or n${NC}"
    done
    
    if [[ "$enabled" =~ ^[Yy] ]]; then
      # تنظیم پورت
      while true; do
        read -p "Port for ${PROTOCOLS[i]} [${DEFAULT_PORTS[i]}]: " port
        port=${port:-${DEFAULT_PORTS[i]}}
        if validate_port "$port"; then
          break
        fi
      done
      
      # تنظیم پروتکل برای OpenVPN
      if [ "${PROTOCOLS[i]}" == "OpenVPN" ]; then
        echo -e "${YELLOW}🔘 OpenVPN Protocol Selection${NC}"
        while true; do
          echo "1) TCP (Recommended for stability)"
          echo "2) UDP (Better performance)"
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
      echo -e "${GREEN}✅ ${PROTOCOLS[i]} configured on port ${port}/${proto}${NC}"
    else
      CONFIG["${PROTOCOLS[i]},enabled"]=0
      echo -e "${YELLOW}⚠️ ${PROTOCOLS[i]} disabled${NC}"
    fi
  done
}

# تابع دریافت سرورهای بک‌اند
get_backend_servers() {
  echo -e "\n${YELLOW}🌐 Backend Server Configuration${NC}"
  echo "Enter backend servers (IP or domain, comma separated)"
  echo "Example: 1.1.1.1,2.2.2.2 or vpn1.example.com,vpn2.example.com"
  
  while true; do
    read -p "Backend servers: " backend_input
    if [ -z "$backend_input" ]; then
      echo -e "${RED}❌ Error: Backend servers cannot be empty!${NC}"
      continue
    fi
    
    IFS=',' read -ra SERVER_LIST <<< "$backend_input"
    BACKEND_IPS=()
    INVALID_SERVERS=()
    
    for server in "${SERVER_LIST[@]}"; do
      server=$(echo "$server" | xargs) # حذف فاصله‌های اضافی
      if [[ $server =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        BACKEND_IPS+=("$server")
      else
        # بررسی دامنه
        resolved_ips=($(dig +short "$server" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'))
        if [ ${#resolved_ips[@]} -eq 0 ]; then
          INVALID_SERVERS+=("$server")
        else
          BACKEND_IPS+=("${resolved_ips[@]}")
        fi
      fi
    done

    if [ ${#BACKEND_IPS[@]} -eq 0 ]; then
      echo -e "${RED}❌ Error: No valid backend servers found!${NC}"
      if [ ${#INVALID_SERVERS[@]} -gt 0 ]; then
        echo -e "${YELLOW}⚠️ Could not resolve: ${INVALID_SERVERS[*]}${NC}"
      fi
      continue
    else
      break
    fi
  done

  echo -e "\n${GREEN}✅ Valid Backend Servers:${NC}"
  printf '  %s\n' "${BACKEND_IPS[@]}"
  
  if [ ${#INVALID_SERVERS[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}⚠️ Unresolved Servers (skipped):${NC}"
    printf '  %s\n' "${INVALID_SERVERS[@]}"
  fi
}

# تابع تولید کانفیگ HAProxy
generate_haproxy_config() {
  echo -e "\n${YELLOW}📝 Generating HAProxy configuration...${NC}"
  
  # ایجاد فایل کانفیگ با محتوای اصلی
  cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0 info
    maxconn 10000
    tune.ssl.default-dh-param 2048
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
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
    default-server inter 10s downinter 5s rise 2 fall 2 slowstart 60s maxconn 1000 maxqueue 128
EOF

  # تولید کانفیگ برای هر پروتکل فعال
  for i in "${!PROTOCOLS[@]}"; do
    if [ "${CONFIG["${PROTOCOLS[i]},enabled"]}" -eq 1 ]; then
      port=${CONFIG["${PROTOCOLS[i]},port"]}
      proto=${CONFIG["${PROTOCOLS[i]},proto"]}
      algo=${ALGORITHMS[i]}
      sticky=${STICKY_TIMEOUTS[i]}

      echo -e "\n# ${PROTOCOLS[i]} Configuration" >> /etc/haproxy/haproxy.cfg
      cat >> /etc/haproxy/haproxy.cfg <<EOF
frontend ${PROTOCOLS[i],,}_front
    bind *:${port} ${proto}
    mode ${proto}
    default_backend ${PROTOCOLS[i],,}_back

backend ${PROTOCOLS[i],,}_back
    mode ${proto}
    balance ${algo}
EOF

      # تنظیمات پایداری جلسه
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
      for ip in "${BACKEND_IPS[@]}"; do
        echo "    server ${PROTOCOLS[i],,}_${ip//./_} ${ip}:${port} check" >> /etc/haproxy/haproxy.cfg
      done
    fi
  done

  # نمایش خلاصه کانفیگ
  echo -e "\n${GREEN}✅ HAProxy configuration generated successfully${NC}"
  echo -e "${YELLOW}📜 Configuration summary:${NC}"
  grep -E 'frontend|backend|bind|server' /etc/haproxy/haproxy.cfg | sed 's/^/  /'
}

# تابع تنظیم فایروال
configure_firewall() {
  echo -e "\n${YELLOW}🔥 Configuring firewall...${NC}"
  
  # Reset firewall (برای جلوگیری از تداخل)
  echo -e "${YELLOW}⚠️ Resetting firewall rules...${NC}"
  ufw --force reset > /dev/null
  ufw default deny incoming > /dev/null
  ufw default allow outgoing > /dev/null
  
  # Allow SSH (برای جلوگیری از قفل شدن)
  ufw allow 22/tcp > /dev/null
  
  # Allow HAProxy ports
  for i in "${!PROTOCOLS[@]}"; do
    if [ "${CONFIG["${PROTOCOLS[i]},enabled"]}" -eq 1 ]; then
      port=${CONFIG["${PROTOCOLS[i]},port"]}
      proto=${CONFIG["${PROTOCOLS[i]},proto"]}
      ufw allow "${port}/${proto}" > /dev/null
      echo -e "${GREEN}✅ Allowed ${proto^^} port ${port}${NC}"
    fi
  done
  
  # Enable firewall
  ufw --force enable > /dev/null
  echo -e "\n${GREEN}✅ Firewall configured successfully${NC}"
  echo -e "${YELLOW}📜 Firewall status:${NC}"
  ufw status numbered | sed 's/^/  /'
}

# تابع راه‌اندازی سرویس‌ها
setup_services() {
  echo -e "\n${YELLOW}⚙️ Setting up services...${NC}"
  
  # ایجاد سرویس ریست خودکار
  cat > /etc/systemd/system/haproxy-tunnel.service <<EOF
[Unit]
Description=HAProxy Tunnel Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/haproxy -f /etc/haproxy/haproxy.cfg -db
Restart=always
RestartSec=5s
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

  # ایجاد تایمر برای ریست دوره‌ای
  cat > /etc/systemd/system/haproxy-tunnel.timer <<EOF
[Unit]
Description=HAProxy Tunnel Auto-Restart

[Timer]
OnBootSec=6h
OnUnitActiveSec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF

  # فعال‌سازی سرویس‌ها
  systemctl daemon-reload
  systemctl enable haproxy-tunnel.service haproxy-tunnel.timer > /dev/null
  systemctl start haproxy-tunnel.service haproxy-tunnel.timer
  
  # بررسی وضعیت سرویس
  echo -e "\n${GREEN}✅ Services configured successfully${NC}"
  echo -e "${YELLOW}📜 Service status:${NC}"
  systemctl status haproxy-tunnel.service --no-pager -l | sed 's/^/  /'
}

# تابع نمایش خلاصه نصب
show_summary() {
  echo -e "\n${GREEN}🎉 Installation completed successfully!${NC}"
  echo -e "${YELLOW}📢 Configuration Summary:${NC}"
  
  # نمایش پروتکل‌های فعال
  echo -e "${YELLOW}🔌 Active Protocols:${NC}"
  for i in "${!PROTOCOLS[@]}"; do
    if [ "${CONFIG["${PROTOCOLS[i]},enabled"]}" -eq 1 ]; then
      echo -e "  ${GREEN}✓${NC} ${PROTOCOLS[i]} (Port: ${CONFIG["${PROTOCOLS[i]},port"]}/${CONFIG["${PROTOCOLS[i]},proto"]})"
    else
      echo -e "  ${RED}✗${NC} ${PROTOCOLS[i]} (Disabled)"
    fi
  done
  
  # نمایش سرورهای بک‌اند
  echo -e "\n${YELLOW}🌐 Backend Servers:${NC}"
  printf '  %s\n' "${BACKEND_IPS[@]}"
  
  # نمایش دستورات مفید
  echo -e "\n${YELLOW}🔧 Useful Commands:${NC}"
  echo "  Check HAProxy status: systemctl status haproxy-tunnel.service"
  echo "  View HAProxy logs: journalctl -u haproxy-tunnel.service -f"
  echo "  Test OpenVPN connection: nc -zv localhost ${CONFIG["OpenVPN,port"]}"
  
  # نمایش نکات مهم
  echo -e "\n${YELLOW}📢 Important Notes:${NC}"
  echo "  1. For OpenVPN, ensure your backend servers:"
  echo "     - Use the same port (${CONFIG["OpenVPN,port"]})"
  echo "     - Use ${CONFIG["OpenVPN,proto"]} protocol"
  echo "  2. System will auto-restart every 6 hours for stability"
  echo "  3. Check firewall status with: ufw status"
  
  echo -e "\n${GREEN}🚀 Happy tunneling!${NC}"
}

# تابع اصلی
main() {
  show_header
  check_root
  check_ubuntu_version
  install_haproxy
  install_deps
  configure_protocols
  get_backend_servers
  generate_haproxy_config
  configure_firewall
  setup_services
  show_summary
}

# اجرای اسکریپت
main
