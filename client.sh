
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run this script with sudo."
    exit 1
fi

WG_DIR="/etc/wireguard"

echo
echo "IPv4Bridge Client"
echo "1) Generate client key"
echo "2) Connect to AWS gateway"
read -rp "Choose [1/2]: " choice

case "$choice" in
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
        echo "Copy this public key into gateway.sh when you run it on AWS."
        ;;
    2)
        [[ -f "$WG_DIR/client.key" ]] || {
            echo "Generate a key first using option 1."
            exit 1
        }

        read -rp "AWS public IPv4: " AWS_IP
        read -rp "AWS WireGuard public key: " SERVER_PUB

        [[ "$AWS_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
            echo "Invalid IPv4 address."
            exit 1
        }

        [[ "$SERVER_PUB" =~ ^[A-Za-z0-9+/]{43}=$ ]] || {
            echo "Invalid WireGuard public key."
            exit 1
        }

        cat > "$WG_DIR/wg0.conf" <<EOF
[Interface]
Address = 10.77.0.2/24
PrivateKey = $(cat "$WG_DIR/client.key")
PostUp = iptables -I INPUT -i %i -p tcp --dport 8080 -j ACCEPT
PostDown = iptables -D INPUT -i %i -p tcp --dport 8080 -j ACCEPT

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $AWS_IP:51820
AllowedIPs = 10.77.0.1/32
PersistentKeepalive = 25
EOF

        chmod 600 "$WG_DIR/wg0.conf"
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard iptables
        systemctl enable wg-quick@wg0
        systemctl restart wg-quick@wg0 2>/dev/null || systemctl start wg-quick@wg0

        echo
        wg show
        ;;
    *)
        echo "Choose 1 or 2."
        exit 1
        ;;
esac
