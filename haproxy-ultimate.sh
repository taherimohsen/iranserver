#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear
echo -e "${GREEN}🚀 Ultimate HAProxy Tunnel Manager${NC}"
echo -e "${GREEN}================================${NC}"

# تنظیمات پایه
PORTS=("4234" "41369" "41374" "42347")
PROTOCOLS=("SSH" "Vless" "Vmess" "OpenVPN")
ALGORITHMS=("source" "roundrobin" "roundrobin" "source")
STICKY_TIMEOUTS=("4h" "0" "0" "6h")

# تابع پرسش از کاربر
ask() {
  read -p "$1: " answer
  echo "$answer"
}

# تابع تشخیص پروتکل OpenVPN
detect_ovpn_protocol() {
  local target_ip=$1
  echo -e "\n${YELLOW}🔘 OpenVPN Protocol for ${target_ip}:${NC}"
  echo "1) TCP (Recommended with HAProxy)"
  echo "2) UDP (Better performance)"
  choice=$(ask "Choose protocol [1-2] (default:1)")
  case $choice in
    2) echo "udp" ;;
    *) echo "tcp" ;;
  esac
}

# تابع تولید کانفیگ ایران
configure_iran() {
  echo -e "\n${GREEN}🔵 Configuring IRAN Server (Load Balancer)${NC}"

  # دریافت لیست سرورهای خارجی
  echo -e "\n${YELLOW}🌐 Backend Server Configuration:${NC}"
  echo "Enter backend servers (domain/IP, comma separated)"
  echo "Example: server1.vpn.com,server2.vpn.com OR 1.1.1.1,2.2.2.2"
  backend_servers=$(ask "Backend servers (default: ssh.vipconfig.ir)")
  backend_servers=${backend_servers:-"ssh.vipconfig.ir"}
  
  IFS=',' read -ra SERVER_LIST <<< "$backend_servers"
  BACKEND_IPS=()
  for server in "${SERVER_LIST[@]}"; do
    if [[ $server =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      BACKEND_IPS+=("$server")
    else
      resolved_ips=($(dig +short "$server"))
      if [ ${#resolved_ips[@]} -eq 0 ]; then
        echo -e "${RED}❌ Could not resolve: $server${NC}"
      else
        BACKEND_IPS+=("${resolved_ips[@]}")
      fi
    fi
  done

  if [ ${#BACKEND_IPS[@]} -eq 0 ]; then
    echo -e "${RED}❌ No valid backend servers found!${NC}"
    exit 1
  fi

  echo -e "\n${GREEN}✅ Detected Backend IPs:${NC}"
  printf '%s\n' "${BACKEND_IPS[@]}"

  # تشخیص پروتکل OpenVPN برای هر سرور
  declare -A OVPN_PROTOCOLS
  for ip in "${BACKEND_IPS[@]}"; do
    OVPN_PROTOCOLS["$ip"]=$(detect_ovpn_protocol "$ip")
  done

  # تولید فایل کانفیگ
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

  # تولید کانفیگ برای هر پروتکل
  for i in "${!PROTOCOLS[@]}"; do
    port=${PORTS[i]}
    proto=${PROTOCOLS[i]}
    algo=${ALGORITHMS[i]}
    sticky=${STICKY_TIMEOUTS[i]}

    cat >> /etc/haproxy/haproxy.cfg <<EOF

frontend ${proto}_front
    bind *:${port}
    default_backend ${proto}_back

backend ${proto}_back
    mode tcp
    balance ${algo}
EOF

    # تنظیمات خاص OpenVPN
    if [ "$proto" == "OpenVPN" ]; then
      for ip in "${!OVPN_PROTOCOLS[@]}"; do
        if [ "${OVPN_PROTOCOLS[$ip]}" == "udp" ]; then
          cat >> /etc/haproxy/haproxy.cfg <<EOF
    server ${proto}_${ip//./_} ${ip}:${port} check send-proxy
EOF
        else
          cat >> /etc/haproxy/haproxy.cfg <<EOF
    server ${proto}_${ip//./_} ${ip}:${port} check
EOF
        fi
      done
    else
      # سایر پروتکل‌ها
      for ip in "${BACKEND_IPS[@]}"; do
        cat >> /etc/haproxy/haproxy.cfg <<EOF
    server ${proto}_${ip//./_} ${ip}:${port} check
EOF
      done
    fi

    # تنظیمات پایداری جلسه
    if [ "$sticky" != "0" ]; then
      cat >> /etc/haproxy/haproxy.cfg <<EOF
    stick-table type ip size 200k expire ${sticky}
    stick on src
EOF
    fi

    # فعال‌سازی فایروال
    ufw allow "${port}"/tcp
    if [ "$proto" == "OpenVPN" ]; then
      ufw allow "${port}"/udp
    fi
  done

  # تنظیم سرویس ریست خودکار
  configure_auto_restart
  
  echo -e "\n${GREEN}✅ IRAN Server configured successfully!${NC}"
}

# تابع پیکربندی سرور خارج
configure_kharej() {
  echo -e "\n${GREEN}🔵 Configuring Kharej Server (Backend)${NC}"

  # دریافت تنظیمات OpenVPN
  OVPN_PROTO=$(detect_ovpn_protocol "localhost")
  OVPN_PORT=42347

  # تولید فایل کانفیگ
  cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    maxconn 5000
    daemon

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 5s
    timeout client 1h
    timeout server 1h
EOF

  # تولید کانفیگ برای هر پروتکل
  for i in "${!PROTOCOLS[@]}"; do
    port=${PORTS[i]}
    proto=${PROTOCOLS[i]}

    cat >> /etc/haproxy/haproxy.cfg <<EOF

frontend ${proto}_front
    bind *:${port}
    default_backend ${proto}_back

backend ${proto}_back
EOF

    if [ "$proto" == "OpenVPN" ]; then
      cat >> /etc/haproxy/haproxy.cfg <<EOF
    mode ${OVPN_PROTO}
    server local_${proto} 127.0.0.1:1194
EOF
    else
      cat >> /etc/haproxy/haproxy.cfg <<EOF
    server local_${proto} 127.0.0.1:${port}
EOF
    fi

    # فعال‌سازی فایروال
    ufw allow "${port}"/tcp
    if [ "$proto" == "OpenVPN" ]; then
      ufw allow "${port}"/udp
    fi
  done

  echo -e "\n${GREEN}✅ Kharej Server configured successfully!${NC}"
}

# تابع تنظیم ریست خودکار
configure_auto_restart() {
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
  systemctl enable haproxy-reset.timer
  systemctl start haproxy-reset.timer
}

# نصب پیش‌نیازها
install_dependencies() {
  echo -e "\n${YELLOW}🔧 Installing dependencies...${NC}"
  apt update
  apt install -y haproxy ufw netcat dnsutils
}

# منوی اصلی
main_menu() {
  while true; do
    echo -e "\n${YELLOW}🔘 Main Menu:${NC}"
    echo "1) Configure IRAN Server (Load Balancer)"
    echo "2) Configure Kharej Server (Backend)"
    echo "3) Exit"
    choice=$(ask "Select option [1-3]")
    
    case $choice in
      1) configure_iran ;;
      2) configure_kharej ;;
      3) break ;;
      *) echo -e "${RED}Invalid option!${NC}" ;;
    esac
  done
}

# شروع اجرای اسکریپت
install_dependencies
main_menu

systemctl restart haproxy
systemctl enable haproxy
ufw --force enable

echo -e "\n${GREEN}🎉 All configurations completed successfully!${NC}"
echo -e "${YELLOW}📢 Important Notes:${NC}"
echo "1. OpenVPN servers must be pre-configured"
echo "2. For UDP support, enable UDP in OpenVPN server config"
echo "3. System will auto-reset every 6 hours"
echo -e "\n${GREEN}🚀 Happy tunneling!${NC}"
