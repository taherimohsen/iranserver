#!/bin/bash
echo "🚀 شروع نصب HAProxy و تنظیم خودکار load‑balancing..."

# نصب پیش‌نیازها
apt update -y && apt install -y haproxy dnsutils ufw

# دریافت IPهای سرورهای خارجی
REMOTE="ssh.vipconfig.ir"
IP_LIST=$(dig +short $REMOTE | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
if [ -z "$IP_LIST" ]; then
  echo "❗ خطا: IP معتبری از $REMOTE دریافت نشد!"
  exit 1
fi

# پشتیبان‌گیری از فایل کانفیگ HAProxy
cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak 2>/dev/null || true

# ساخت فایل کانفیگ جدید
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

frontend ssh_in
    bind *:4234
    default_backend ssh_out

frontend vmess_in
    bind *:41369
    default_backend vmess_out

frontend vless_in
    bind *:41374
    default_backend vless_out

frontend openvpn_in
    bind *:42347
    default_backend openvpn_out
EOF

# اضافه کردن بخش backend برای هر پورت
for PORT in 4234 41369 41374 42347; do
  cat >> /etc/haproxy/haproxy.cfg <<EOF

backend ${PORT}_out
    mode tcp
    balance first
    option tcp-check
    tcp-check connect port $PORT
    default-server inter 2s fall 2 rise 1 check
EOF
  for IP in $IP_LIST; do
    echo "    server srv_${PORT}_$(echo $IP | tr '.' '_') $IP:$PORT check" >> /etc/haproxy/haproxy.cfg
  done
done

# راه‌اندازی HAProxy
systemctl restart haproxy
systemctl enable haproxy

# باز کردن پورت‌ها
ufw allow 4234/tcp
ufw allow 41369/tcp
ufw allow 41374/tcp
ufw allow 42347/tcp

echo -e "\n✅ نصب کامل شد. پورت‌ها و IPهای استفاده‌شده:"
echo "$IP_LIST"
