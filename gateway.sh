
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run this script with sudo."
    exit 1
fi

echo
echo "IPv4Bridge Gateway"
read -rp "Client public key: " CLIENT_PUB

[[ "$CLIENT_PUB" =~ ^[A-Za-z0-9+/]{43}=$ ]] || {
    echo "Invalid WireGuard public key."
    exit 1
}

PUB_IF=$(ip -o route get 1.1.1.1 | awk '{print $5; exit}')

[[ -n "$PUB_IF" ]] || {
    echo "Could not detect the public network interface."
    exit 1
}

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard iptables

install -d -m 700 /etc/wireguard
umask 077

if [[ ! -f /etc/wireguard/server.key ]]; then
    wg genkey | tee /etc/wireguard/server.key | wg pubkey > /etc/wireguard/server.pub
fi

SERVER_KEY=$(cat /etc/wireguard/server.key)

cat > /etc/sysctl.d/99-ipv4bridge.conf <<'EOF'
net.ipv4.ip_forward=1
EOF

sysctl --system >/dev/null

cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = 10.77.0.1/24
ListenPort = 51820
PrivateKey = $SERVER_KEY
PostUp = iptables -I INPUT -p udp --dport 51820 -j ACCEPT
PostUp = iptables -t nat -A PREROUTING -i $PUB_IF -p tcp --dport 8080 -j DNAT --to-destination 10.77.0.2:8080
PostUp = iptables -t nat -A POSTROUTING -o %i -p tcp -d 10.77.0.2 --dport 8080 -j MASQUERADE
PostUp = iptables -I FORWARD -i $PUB_IF -o %i -p tcp -d 10.77.0.2 --dport 8080 -j ACCEPT
PostUp = iptables -I FORWARD -i %i -o $PUB_IF -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostDown = iptables -D INPUT -p udp --dport 51820 -j ACCEPT
PostDown = iptables -t nat -D PREROUTING -i $PUB_IF -p tcp --dport 8080 -j DNAT --to-destination 10.77.0.2:8080
PostDown = iptables -t nat -D POSTROUTING -o %i -p tcp -d 10.77.0.2 --dport 8080 -j MASQUERADE
PostDown = iptables -D FORWARD -i $PUB_IF -o %i -p tcp -d 10.77.0.2 --dport 8080 -j ACCEPT
PostDown = iptables -D FORWARD -i %i -o $PUB_IF -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

[Peer]
PublicKey = $CLIENT_PUB
AllowedIPs = 10.77.0.2/32
EOF

chmod 600 /etc/wireguard/wg0.conf
systemctl enable wg-quick@wg0
systemctl restart wg-quick@wg0 2>/dev/null || systemctl start wg-quick@wg0

echo
echo "AWS WireGuard public key:"
cat /etc/wireguard/server.pub
echo
echo "Gateway configured."
echo "Allow UDP 51820 and TCP 8080 in the AWS security group."
echo "Next, run client.sh and choose option 2 on the other server."
