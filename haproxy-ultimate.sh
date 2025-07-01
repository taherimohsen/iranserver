#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# تنظیمات اولیه
PROTOCOLS=("SSH" "Vless" "Vmess" "OpenVPN")
DEFAULT_PORTS=("4234" "41369" "41374" "42347")
ALGORITHMS=("source" "roundrobin" "roundrobin" "source")
STICKY_TIMEOUTS=("4h" "0" "0" "6h")

clear
echo -e "${GREEN}🚀 Ultimate HAProxy Tunnel Manager${NC}"
echo -e "${GREEN}================================${NC}"

# تابع نمایش منوی اصلی
show_main_menu() {
  echo -e "\n${YELLOW}🔘 Main Menu:${NC}"
  echo "1) Configure IRAN Server (Load Balancer)"
  echo "2) Configure Kharej Server (Backend)"
  echo "3) Exit"
  read -p "Select option [1-3]: " main_choice
}

# تابع پیکربندی پروتکل‌ها
configure_protocols() {
  declare -A CONFIG
  for i in "${!PROTOCOLS[@]}"; do
    echo -e "\n${YELLOW}🔧 Configuring ${PROTOCOLS[i]}${NC}"
    read -p "Enable ${PROTOCOLS[i]}? (y/n) [y]: " enabled
    enabled=${enabled:-y}
    
    if [[ "$enabled" =~ ^[Yy] ]]; then
      read -p "Enter port for ${PROTOCOLS[i]} [${DEFAULT_PORTS[i]}]: " port
      port=${port:-${DEFAULT_PORTS[i]}}
      
      if [ "${PROTOCOLS[i]}" == "OpenVPN" ]; then
        echo -e "${YELLOW}🔘 Select OpenVPN Protocol:${NC}"
        echo "1) TCP (Recommended with HAProxy)"
        echo "2) UDP (Better performance)"
        read -p "Choose [1-2] (default:1): " proto_choice
        case $proto_choice in
          2) proto="udp" ;;
          *) proto="tcp" ;;
        esac
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

# تابع پیکربندی سرور ایران
configure_iran() {
  echo -e "\n${GREEN}🔵 Configuring IRAN Server (Load Balancer)${NC}"
  
  # دریافت لیست سرورهای خارجی
  echo -e "\n${YELLOW}🌐 Backend Server Configuration:${NC}"
  echo "Enter backend servers (domain/IP, comma separated)"
  echo "Example: server1.vpn.com,server2.vpn.com OR 1.1.1.1,2.2.2.2"
  read -p "Backend servers (default: ssh.vipconfig.ir): " backend_servers
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

  # تولید کانفیگ برای هر پروتکل فعال
  for i in "${!PROTOCOLS[@]}"; do
    if [ "${CONFIG["${PROTOCOLS[i]},enabled"]}" -eq 1 ]; then
      port=${CONFIG["${PROTOCOLS[i]},port"]}
      proto=${CONFIG["${PROTOCOLS[i]},proto"]}
      algo=${ALGORITHMS[i]}
      sticky=${STICKY_TIMEOUTS[i]}

      cat >> /etc/haproxy/haproxy.cfg <<EOF

frontend ${PROTOCOLS[i]}_front
    bind *:${port} ${proto}
    default_backend ${PROTOCOLS[i]}_back

backend ${PROTOCOLS[i]}_back
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

      # اضافه کردن سرورهای backend
      for ip in "${BACKEND_IPS[@]}"; do
        echo "    server ${PROTOCOLS[i]}_${ip//./_} ${ip}:${port} check" >> /etc/haproxy/haproxy.cfg
      done

      # فعال‌سازی فایروال
      ufw allow "${port}/${proto}"
    fi
  done

  # تنظیم سرویس ریست خودکار
  configure_auto_restart
  
  echo -e "\n${GREEN}✅ IRAN Server configured successfully!${NC}"
}

# تابع پیکربندی سرور خارج
configure_kharej() {
  echo -e "\n${GREEN}🔵 Configuring Kharej Server (Backend)${NC}"

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

  # تولید کانفیگ برای هر پروتکل فعال
  for i in "${!PROTOCOLS[@]}"; do
    if [ "${CONFIG["${PROTOCOLS[i]},enabled"]}" -eq 1 ]; then
      port=${CONFIG["${PROTOCOLS[i]},port"]}
      proto=${CONFIG["${PROTOCOLS[i]},proto"]}

      cat >> /etc/haproxy/haproxy.cfg <<EOF

frontend ${PROTOCOLS[i]}_front
    bind *:${port} ${proto}
    default_backend ${PROTOCOLS[i]}_back

backend ${PROTOCOLS[i]}_back
    mode ${proto}
    server local_${PROTOCOLS[i],,} 127.0.0.1:${port}
EOF

      # فعال‌سازی فایروال
      ufw allow "${port}/${proto}"
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
  echo -e "\n${YELLOW}📦 Installing dependencies...${NC}"
  apt update
  apt install -y haproxy ufw netcat dnsutils
}

# شروع اجرای اسکریپت
install_dependencies

while true; do
  show_main_menu
  case $main_choice in
    1)
      configure_protocols
      configure_iran
      ;;
    2)
      configure_protocols
      configure_kharej
      ;;
    3)
      break
      ;;
    *)
      echo -e "${RED}Invalid option!${NC}"
      ;;
  esac
done

systemctl restart haproxy
systemctl enable haproxy
ufw --force enable

echo -e "\n${GREEN}🎉 All configurations completed successfully!${NC}"
echo -e "${YELLOW}📢 Important Notes:${NC}"
echo "1. For OpenVPN UDP, ensure your backend servers support UDP"
echo "2. The system will auto-reset every 6 hours"
echo -e "\n${GREEN}🚀 Happy tunneling!${NC}"
