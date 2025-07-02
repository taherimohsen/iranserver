#!/bin/bash

# تنظیمات پایه
PROTOCOLS=("SSH" "Vless" "Vmess" "OpenVPN")
DEFAULT_PORTS=("4234" "41369" "41374" "42347")
ALGORITHMS=("source" "roundrobin" "roundrobin" "source")
STICKY_TIMEOUTS=("4h" "0" "0" "8h")  # زمان ماندگاری سشن

clear
echo "🚀 Ultimate HAProxy Tunnel Manager - Fixed Version"
echo "================================================"

# انتخاب موقعیت سرور
read -p "Is the server located in Iran? (y/n): " is_iran
if [ "$is_iran" = "y" ]; then
  echo "Applying optimized settings for Iran"
  SERVER_LOCATION="iran"
else
  echo "Applying settings for foreign servers"
  SERVER_LOCATION="foreign"
fi

# انتخاب پروتکل‌ها
echo "Please select required protocols:"
for i in "${!PROTOCOLS[@]}"; do
  read -p "Enable ${PROTOCOLS[i]} (port ${DEFAULT_PORTS[i]})? (y/n): " enable_proto
  if [ "$enable_proto" = "y" ]; then
    while true; do
      read -p "Custom port for ${PROTOCOLS[i]} (default ${DEFAULT_PORTS[i]}): " custom_port
      port=${custom_port:-${DEFAULT_PORTS[i]}}
      if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; then
        PORTS[i]=$port
        break
      else
        echo "❌ Invalid port! Must be between 1024 and 65535"
      fi
    done
    
    # انتخاب پروتکل برای OpenVPN
    if [ "${PROTOCOLS[i]}" = "OpenVPN" ]; then
      echo "Select OpenVPN protocol:"
      echo "1) TCP (Recommended)"
      echo "2) UDP (High performance)"
      read -p "Your choice [1-2]: " proto_choice
      case $proto_choice in
        2) PROTOCOL_TYPES[i]="udp" ;;
        *) PROTOCOL_TYPES[i]="tcp" ;;
      esac
    else
      PROTOCOL_TYPES[i]="tcp"
    fi
    
    ENABLED_PROTOCOLS+=("${PROTOCOLS[i]}")
  else
    PORTS[i]=""
    PROTOCOL_TYPES[i]=""
  fi
done

# دریافت سرورهای بک‌اند
read -p "Enter backend server IPs/Domains (comma separated, leave empty for default): " backend_servers
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
  
  # Resolve domains to IPs
  RESOLVED_SERVERS=()
  for server in "${BACKEND_SERVERS[@]}"; do
    if [[ $server =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      RESOLVED_SERVERS+=("$server")
    else
      resolved_ips=($(dig +short "$server"))
      if [ ${#resolved_ips[@]} -eq 0 ]; then
        echo "⚠️ Could not resolve: $server"
      else
        RESOLVED_SERVERS+=("${resolved_ips[@]}")
      fi
    fi
  done
  BACKEND_SERVERS=("${RESOLVED_SERVERS[@]}")
fi

# بررسی سلامت سرورها
check_server_health() {
  local ip=$1
  local port=$2
  local proto=$3
  
  if [ "$proto" = "udp" ]; then
    # تست اتصال UDP با timeout
    timeout 3 bash -c "echo > /dev/udp/$ip/$port" &>/dev/null
    return $?
  else
    # تست اتصال TCP
    nc -z -w 3 "$ip" "$port" &>/dev/null
    return $?
  fi
}

# تولید فایل کانفیگ HAProxy
generate_config() {
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
    timeout connect 5s
    timeout client 1h
    timeout server 1h
EOF

  for i in "${!PROTOCOLS[@]}"; do
    if [ -n "${PORTS[i]}" ]; then
      proto=${PROTOCOL_TYPES[i]}
      
      cat >> /etc/haproxy/haproxy.cfg <<EOF

frontend ${PROTOCOLS[i]}_front
    bind *:${PORTS[i]} ${proto}
    mode ${proto}
    default_backend ${PROTOCOLS[i]}_back

backend ${PROTOCOLS[i]}_back
    mode ${proto}
    balance ${ALGORITHMS[i]}
EOF

      # تنظیمات خاص OpenVPN
      if [ "${PROTOCOLS[i]}" = "OpenVPN" ]; then
        cat >> /etc/haproxy/haproxy.cfg <<EOF
    option tcpka
    timeout tunnel 86400s
EOF
      fi

      # تنظیمات sticky session
      if [ "${STICKY_TIMEOUTS[i]}" != "0" ]; then
        cat >> /etc/haproxy/haproxy.cfg <<EOF
    stick-table type ip size 200k expire ${STICKY_TIMEOUTS[i]}
    stick on src
EOF
      fi

      # اضافه کردن سرورهای فعال
      active_servers=0
      for ip in "${BACKEND_SERVERS[@]}"; do
        if check_server_health "$ip" "${PORTS[i]}" "${PROTOCOL_TYPES[i]}"; then
          echo "    server ${PROTOCOLS[i]}_${ip//./_} $ip:${PORTS[i]} check" >> /etc/haproxy/haproxy.cfg
          active_servers=$((active_servers+1))
        else
          echo "    #server ${PROTOCOLS[i]}_${ip//./_} $ip:${PORTS[i]} check  # INACTIVE" >> /etc/haproxy/haproxy.cfg
        fi
      done
      
      if [ $active_servers -eq 0 ]; then
        echo "    server ${PROTOCOLS[i]}_fallback 127.0.0.1:${PORTS[i]} backup" >> /etc/haproxy/haproxy.cfg
        echo "⚠️ Warning: No active servers found for ${PROTOCOLS[i]}, added fallback server"
      fi

      # باز کردن پورت در فایروال
      ufw allow "${PORTS[i]}/${PROTOCOL_TYPES[i]}"
    fi
  done
}

# ریست و بررسی سلامت
reset_and_check() {
  echo "🔄 Resetting tunnels and checking servers..."

  for i in "${!PROTOCOLS[@]}"; do
    if [ -n "${PORTS[i]}" ]; then
      for ip in "${BACKEND_SERVERS[@]}"; do
        if ! check_server_health "$ip" "${PORTS[i]}" "${PROTOCOL_TYPES[i]}"; then
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

# تنظیم سرویس‌های خودکار
setup_services() {
  # سرویس ریست دوره‌ای
  cat > /etc/systemd/system/haproxy-reset.service <<EOF
[Unit]
Description=HAProxy Reset and Health Check
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '$(declare -f reset_and_check); reset_and_check'
EOF

  # تایمر 6 ساعته
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

  # سرویس راه‌اندازی خودکار
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

# نصب پیش‌نیازها
echo "Installing prerequisites..."
apt update && apt install -y haproxy ufw netcat-openbsd dnsutils

# بررسی نسخه HAProxy برای پشتیبانی از UDP
if ! haproxy -v | grep -q "2.4"; then
  echo "Upgrading HAProxy to version 2.4+ for UDP support..."
  add-apt-repository -y ppa:vbernat/haproxy-2.4
  apt update
  apt install -y haproxy=2.4.*
fi

echo "Generating configuration..."
generate_config

echo "Setting up automatic services..."
setup_services

systemctl restart haproxy
systemctl enable haproxy
ufw --force enable

# نمایش خلاصه نصب
echo -e "\n🎉 Configuration completed successfully!"
echo "📋 Active protocols:"
for i in "${!PROTOCOLS[@]}"; do
  if [ -n "${PORTS[i]}" ]; then
    echo "  ${PROTOCOLS[i]}:${PORTS[i]}/${PROTOCOL_TYPES[i]} | Algorithm:${ALGORITHMS[i]} | Sticky:${STICKY_TIMEOUTS[i]}"
  fi
done
echo -e "\n🌐 Backend servers:"
printf '  %s\n' "${BACKEND_SERVERS[@]}"
echo -e "\n🔁 Auto-reset every 6 hours enabled"
echo "🔄 Auto-start after reboot enabled"
