#!/bin/bash

clear
echo "🚀 HAProxy Automatic Start"
echo "==========================="
echo "Choose 1 or 2"
echo "1️⃣ IRAN Server"
echo "2️⃣ Kharej Server"
read -p "Please choose one option [1 or 2]: " MODE

apt update && apt install -y haproxy ufw dnsutils

cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak 2>/dev/null || true

if [ "$MODE" == "1" ]; then
  echo "🟢 IRAN Server is selected.."

  # دریافت IPهای سرورهای خارجی
  IP_LIST=$(dig +short ssh.vipconfig.ir | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}')
  if [ -z "$IP_LIST" ]; then
    echo "Error !!!\nYour SUB Domain no have IP (ssh.vipconfig.ir)"
    exit 1
  fi

  # تنظیمات HAProxy برای فوروارد به خارج
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
      echo "    server srv_${PORT}_$(echo $IP | tr '.' '_') ${IP}:$PORT check" >> /etc/haproxy/haproxy.cfg
    done
  done

  ufw allow 4234/tcp
  ufw allow 41369/tcp
  ufw allow 41374/tcp
  ufw allow 42347/tcp

  echo -e "\n✅ Connection IRAN Server set to this IPs:"
  echo "$IP_LIST"

elif [ "$MODE" == "2" ]; then
  echo "🔵 Kharej Server is selected."

  # تنظیمات HAProxy برای انتقال به localhost
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
    default_backend ssh_local

frontend vmess_in
    bind *:41369
    default_backend vmess_local

frontend vless_in
    bind *:41374
    default_backend vless_local

frontend openvpn_in
    bind *:42347
    default_backend openvpn_local

backend ssh_local
    server local_ssh 127.0.0.1:22

backend vmess_local
    server local_vmess 127.0.0.1:41369

backend vless_local
    server local_vless 127.0.0.1:41374

backend openvpn_local
    server local_openvpn 127.0.0.1:42347
EOF

  ufw allow 4234/tcp
  ufw allow 41369/tcp
  ufw allow 41374/tcp
  ufw allow 42347/tcp

  echo -e "\n✅ Kharej Server is ready for connect to IRAN Server."

else
  echo "❌ Input is incorect. Please try again."
  exit 1
fi

systemctl restart haproxy
systemctl enable haproxy
