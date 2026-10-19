
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run: sudo bash client.sh"
    exit 1
fi

WG_DIR="/etc/wireguard"

echo
echo "IPv4Bridge Client"
echo "1) Generate client key"
echo "2) Connect to AWS gateway"
read -rp "Choose [1/2]: " CHOICE

case "$CHOICE" in
    1)
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard iptables
        install -d -m 700 "$WG_DIR"
        umask 077

        if [[ ! -f "$WG_DIR/client.key" ]]; then
            wg genkey | tee "$WG_DIR/client.key" | wg pubkey > "$WG_DIR/client.pub"
        fi

        echo
        echo "Client public key:"
        cat "$WG_DIR/client.pub"
        echo
        echo "Copy this key into gateway.sh on AWS."
        ;;
    2)
        if [[ ! -f "$WG_DIR/client.key" ]]; then
            echo "Run option 1 first."
            exit 1
        fi

        read -rp "AWS public IPv4: " AWS_IP
        read -rp "AWS WireGuard public key: " SERVER_PUB

        if [[ ! "$AWS_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            echo "Enter the AWS public IPv4 address."
            exit 1
        fi

        if [[ ! "$SERVER_PUB" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
            echo "Invalid WireGuard public key."
            exit 1
        fi

        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard iptables
        install -d -m 700 "$WG_DIR"

        systemctl disable --now wg-quick@wg0 2>/dev/null || true
        ip link delete wg0 2>/dev/null || true

        while iptables -C INPUT -i wg0 -p tcp --dport 8080 -j ACCEPT 2>/dev/null; do
            iptables -D INPUT -i wg0 -p tcp --dport 8080 -j ACCEPT
        done

        cat > "$WG_DIR/wg0.conf" <<EOF
[Interface]
Address = 10.77.0.2/24
PrivateKey = $(cat "$WG_DIR/client.key")
PostUp = iptables -I INPUT -i %i -p tcp --dport 22 -j ACCEPT
PostDown = iptables -D INPUT -i %i -p tcp --dport 22 -j ACCEPT

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $AWS_IP:51820
AllowedIPs = 10.77.0.1/32
PersistentKeepalive = 25
EOF

        chmod 600 "$WG_DIR/wg0.conf"
        systemctl enable --now wg-quick@wg0

        echo
        wg show
        echo
        echo "Check that latest handshake appears above."
        echo "Then connect from your PC using AWS_PUBLIC_IPV4 on port 2222."
        ;;
    *)
        echo "Choose 1 or 2."
        exit 1
        ;;
esac
