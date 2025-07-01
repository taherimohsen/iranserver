#!/bin/bash

# تنظیمات پایه
PROTOCOLS=("SSH" "Vless" "Vmess" "OpenVPN")
DEFAULT_PORTS=("4234" "41369" "41374" "42347")
ALGORITHMS=("source" "roundrobin" "roundrobin" "source")
STICKY_TIMEOUTS=("4h" "0" "0" "6h")  # زمان پایداری جلسات

clear
echo "🚀 Ultimate HAProxy Tunnel Manager"
echo "================================"

# انتخاب موقعیت سرور
read -p "آیا سرور در ایران است؟ (y/n): " is_iran
if [ "$is_iran" = "y" ]; then
  echo "تنظیمات بهینه برای ایران اعمال خواهد شد"
  SERVER_LOCATION="iran"
else
  echo "تنظیمات برای سرور خارج اعمال خواهد شد"
  SERVER_LOCATION="foreign"
fi

# انتخاب پروتکل‌ها
echo "لطفا پروتکل‌های مورد نیاز را انتخاب کنید:"
for i in "${!PROTOCOLS[@]}"; do
  read -p "آیا ${PROTOCOLS[i]} (پورت ${DEFAULT_PORTS[i]}) را فعال کنیم؟ (y/n): " enable_proto
  if [ "$enable_proto" = "y" ]; then
    read -p "پورت مورد نظر برای ${PROTOCOLS[i]} (پیشفرض ${DEFAULT_PORTS[i]}): " custom_port
    PORTS[i]=${custom_port:-${DEFAULT_PORTS[i]}}
    ENABLED_PROTOCOLS+=("${PROTOCOLS[i]}")
  else
    PORTS[i]=""
  fi
done

# دریافت سرورهای بکند
read -p "آدرس سرورهای بکند را وارد کنید (با کاما جدا کنید، یا برای استفاده از ssh.vipconfig.ir خالی بگذارید): " backend_servers
if [ -z "$backend_servers" ]; then
  if [ "$SERVER_LOCATION" = "iran" ]; then
    BACKEND_SERVERS=($(dig +short ssh.vipconfig.ir))
    echo "استفاده از سرورهای پیشفرض ایرانی: ${BACKEND_SERVERS[*]}"
  else
    echo "خطا: برای سرورهای خارجی باید آدرس سرورها را وارد کنید"
    exit 1
  fi
else
  IFS=',' read -ra BACKEND_SERVERS <<< "$backend_servers"
fi

# تابع بررسی سلامت سرورها
check_server_health() {
  local ip=$1
  local port=$2
  nc -z -w 3 "$ip" "$port" &>/dev/null
  return $?
}

# تولید کانفیگ
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

      # تنظیمات پایداری جلسه برای SSH و OpenVPN
      if [ "${STICKY_TIMEOUTS[i]}" != "0" ]; then
        cat >> /etc/haproxy/haproxy.cfg <<EOF
    stick-table type ip size 200k expire ${STICKY_TIMEOUTS[i]}
    stick on src
EOF
      fi

      # اضافه کردن سرورها
      for ip in "${BACKEND_SERVERS[@]}"; do
        echo "    server ${PROTOCOLS[i]}_${ip//./_} $ip:${PORTS[i]} check" >> /etc/haproxy/haproxy.cfg
      done

      ufw allow "${PORTS[i]}"/tcp
    fi
  done
}

# تابع ریست و بررسی سلامت
reset_and_check() {
  echo "🔄 در حال ریست تونل‌ها و بررسی سرورها..."

  # پاکسازی جلسات
  for proto in "${ENABLED_PROTOCOLS[@]}"; do
    if [[ "$proto" == "SSH" || "$proto" == "OpenVPN" ]]; then
      echo "clear table ${proto}_back" | socat /var/run/haproxy.sock stdio
    fi
  done

  # بررسی سلامت سرورها و به‌روزرسانی config
  for i in "${!PROTOCOLS[@]}"; do
    if [ -n "${PORTS[i]}" ]; then
      for ip in "${BACKEND_SERVERS[@]}"; do
        if ! check_server_health "$ip" "${PORTS[i]}"; then
          echo "🚨 سرور ${PROTOCOLS[i]}_${ip//./_} غیرفعال است، در حال غیرفعال کردن..."
          sed -i "/server ${PROTOCOLS[i]}_${ip//./_}/s/^/#/" /etc/haproxy/haproxy.cfg
        else
          echo "✅ سرور ${PROTOCOLS[i]}_${ip//./_} فعال است"
          sed -i "/#server ${PROTOCOLS[i]}_${ip//./_}/s/^#//" /etc/haproxy/haproxy.cfg
        fi
      done
    fi
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
echo "در حال نصب پیش‌نیازها..."
apt update && apt install -y haproxy ufw netcat dnsutils

echo "در حال تولید پیکربندی..."
generate_config

echo "در حال تنظیم سرویس‌های خودکار..."
setup_services

systemctl restart haproxy
systemctl enable haproxy
ufw --force enable

echo -e "\n🎉 پیکربندی با موفقیت انجام شد!"
echo "📋 پروتکل‌های فعال:"
for i in "${!PROTOCOLS[@]}"; do
  if [ -n "${PORTS[i]}" ]; then
    echo "  ${PROTOCOLS[i]}:${PORTS[i]} | الگوریتم: ${ALGORITHMS[i]} | پایداری: ${STICKY_TIMEOUTS[i]}"
  fi
done
echo -e "\n🔁 ریست خودکار هر 6 ساعت فعال شد"
echo "🔄 راه‌اندازی خودکار پس از ریستارت فعال شد"