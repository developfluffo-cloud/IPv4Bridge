#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run: sudo bash client.sh"
    exit 1
fi

WG_DIR="/etc/wireguard"
IS_SYSTEMD=false

if [[ "$(ps -p 1 -o comm= | tr -d ' ')" == "systemd" ]]; then
    IS_SYSTEMD=true
fi

echo
echo "IPv4Bridge Client"
echo "================="
echo "1) Generate client key"
echo "2) Connect to AWS gateway"

read -rp "Choose [1/2]: " CHOICE

case "$CHOICE" in
    1)
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard iptables

        install -d -m 700 "$WG_DIR"
        chmod 700 "$WG_DIR"
        umask 077

        if [[ ! -f "$WG_DIR/client.key" ]]; then
            wg genkey | tee "$WG_DIR/client.key" | wg pubkey > "$WG_DIR/client.pub"
        fi

        chmod 600 "$WG_DIR/client.key"
        chmod 644 "$WG_DIR/client.pub"

        echo
        echo "Client public key:"
        cat "$WG_DIR/client.pub"
        echo
        echo "Copy this public key into gateway.sh on AWS."
        ;;

    2)
        if [[ ! -f "$WG_DIR/client.key" ]]; then
            echo "Run option 1 first."
            exit 1
        fi

        read -rp "AWS public IPv4: " AWS_IP
        read -rp "AWS WireGuard public key: " SERVER_PUB
        read -rp "Destination SSH port [22]: " TARGET_PORT
        TARGET_PORT=${TARGET_PORT:-22}

        if [[ ! "$AWS_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            echo "Enter a valid IPv4 address."
            exit 1
        fi

        IFS='.' read -r -a OCTETS <<< "$AWS_IP"
        for OCTET in "${OCTETS[@]}"; do
            if (( OCTET < 0 || OCTET > 255 )); then
                echo "Invalid IPv4 address."
                exit 1
            fi
        done

        if [[ ! "$SERVER_PUB" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
            echo "Invalid WireGuard public key."
            exit 1
        fi

        if [[ ! "$TARGET_PORT" =~ ^[0-9]+$ ]] || (( TARGET_PORT < 1 || TARGET_PORT > 65535 )); then
            echo "Invalid destination port."
            exit 1
        fi

        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard iptables

        install -d -m 700 "$WG_DIR"

        if [[ "$IS_SYSTEMD" == true ]]; then
            systemctl disable --now wg-quick@wg0 2>/dev/null || true
        else
            wg-quick down wg0 2>/dev/null || true
        fi

        ip link delete wg0 2>/dev/null || true

        for PORT in 22 8080 2222; do
            while iptables -C INPUT -i wg0 -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; do
                iptables -D INPUT -i wg0 -p tcp --dport "$PORT" -j ACCEPT
            done
        done

        cat > "$WG_DIR/wg0.conf" <<EOF
[Interface]
Address = 10.77.0.2/24
PrivateKey = $(cat "$WG_DIR/client.key")
PostUp = iptables -I INPUT -i %i -p tcp --dport $TARGET_PORT -j ACCEPT
PostDown = iptables -D INPUT -i %i -p tcp --dport $TARGET_PORT -j ACCEPT

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $AWS_IP:51820
AllowedIPs = 10.77.0.1/32
PersistentKeepalive = 25
EOF

        chmod 600 "$WG_DIR/wg0.conf"

        if [[ "$IS_SYSTEMD" == true ]]; then
            systemctl enable --now wg-quick@wg0
        else
            wg-quick up wg0
        fi

        echo
        wg show
        echo
        echo "Client configured."
        echo "AWS forwarding port: 2222"
        echo "Destination SSH port: $TARGET_PORT"
        echo "Check that a recent handshake appears above."
        echo "Connect from Windows using:"
        echo "ssh -p 2222 YOUR_USERNAME@$AWS_IP"
        ;;

    *)
        echo "Choose 1 or 2."
        exit 1
        ;;
esac
