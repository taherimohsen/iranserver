#!/bin/bash

# تنظیمات پایه
PROTOCOLS=("SSH" "Vless" "Vmess" "OpenVPN")
PORTS=("4234" "41369" "41374" "42347")
ALGORITHMS=("source" "roundrobin" "roundrobin" "source")
STICKY_TIMEOUTS=("4h" "0" "0" "6h")  # زمان پایداری جلسات

clear
echo "🚀 Ultimate HAProxy Tunnel Manager"
echo "================================"

# تابع بررسی سلامت سرورها
check_server_health() {
  local ip=$1
  local port=$2
  nc -z -w 3 "$ip" "$port" &>/dev/null
  return $?
}

# تولید کانفیگ ایران
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
    cat >> /etc/haproxy/haproxy.cfg <<EOF

frontend ${PROTOCOLS[i]}_front
    bind *:${PORTS[i]}
    default_backend ${PROTOCOLS[i]}_back

backend ${PROTOCOLS[i]}_back
    mode tcp
    balance ${ALGORITHMS[i]}
EOF

    # تنظیمات پایداری جلسه برای SSH و OpenVPN
    if [ "${STICKY_TIMEOUTS[i]}" != "0" ]; then
      cat >> /etc/haproxy/haproxy.cfg <<EOF
    stick-table type ip size 200k expire ${STICKY_TIMEOUTS[i]}
    stick on src
EOF
    fi

    # اضافه کردن سرورها (بدون چک سلامت اولیه)
    for ip in $(dig +short ssh.vipconfig.ir); do
      echo "    server ${PROTOCOLS[i]}_${ip//./_} $ip:${PORTS[i]} check" >> /etc/haproxy/haproxy.cfg
    done
    
    ufw allow "${PORTS[i]}"/tcp
  done
}

# تابع ریست و بررسی سلامت
reset_and_check() {
  echo "🔄 Resetting tunnels and checking servers..."
  
  # پاکسازی جلسات
  echo "clear table SSH_back" | socat /var/run/haproxy.sock stdio
  echo "clear table OpenVPN_back" | socat /var/run/haproxy.sock stdio
  
  # بررسی سلامت سرورها و به‌روزرسانی config
  for i in "${!PROTOCOLS[@]}"; do
    for ip in $(dig +short ssh.vipconfig.ir); do
      if ! check_server_health "$ip" "${PORTS[i]}"; then
        echo "🚨 Server ${PROTOCOLS[i]}_${ip//./_} is OFFLINE, disabling..."
        sed -i "/server ${PROTOCOLS[i]}_${ip//./_}/s/^/#/" /etc/haproxy/haproxy.cfg
      else
        echo "✅ Server ${PROTOCOLS[i]}_${ip//./_} is ONLINE"
        sed -i "/#server ${PROTOCOLS[i]}_${ip//./_}/s/^#//" /etc/haproxy/haproxy.cfg
      fi
    done
  done
  
  systemctl restart haproxy
}

# تنظیم سرویس‌های خودکار
setup_services() {
  # سرویس ریست 6 ساعته
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

  # سرویس راه‌اندازی پس از ریستارت
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

# نصب و راه‌اندازی
apt update && apt install -y haproxy ufw netcat dnsutils
generate_config
setup_services
systemctl restart haproxy
systemctl enable haproxy
ufw --force enable

echo -e "\n🎉 Configuration Completed!"
echo "📋 Active Protocols:"
for i in "${!PROTOCOLS[@]}"; do
  echo "  ${PROTOCOLS[i]}:${PORTS[i]} | Algorithm:${ALGORITHMS[i]} | Sticky:${STICKY_TIMEOUTS[i]}"
done
echo -e "\n🔁 Auto reset every 6 hours enabled"
echo "🔄 Auto-start after reboot enabled"
