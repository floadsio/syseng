#!/bin/sh

# WireGuard Metrics Exporter for Prometheus Node Exporter Textfile Collector
# Exports WireGuard interface statistics in Prometheus format

WG_INTERFACE="${1:-wg0}"
OUTPUT_FILE="${2:-/var/tmp/node_exporter/wireguard.prom}"
TEMP_FILE="${OUTPUT_FILE}.$$"

# Ensure output directory exists
mkdir -p "$(dirname "$OUTPUT_FILE")"

# Write metrics header
cat > "$TEMP_FILE" <<EOF
# HELP wireguard_peer_info WireGuard peer information
# TYPE wireguard_peer_info gauge
# HELP wireguard_peer_latest_handshake_seconds Seconds since last handshake
# TYPE wireguard_peer_latest_handshake_seconds gauge
# HELP wireguard_peer_transfer_bytes_total Total bytes transferred
# TYPE wireguard_peer_transfer_bytes_total counter
# HELP wireguard_peer_keepalive_interval_seconds Keepalive interval in seconds
# TYPE wireguard_peer_keepalive_interval_seconds gauge
EOF

# Parse wg show dump output
# Format: private-key public-key listen-port fwmark
# peer-public-key preshared-key endpoint allowed-ips latest-handshake transfer-rx transfer-tx persistent-keepalive

wg show "$WG_INTERFACE" dump | tail -n +2 | while IFS=$'\t' read -r pubkey psk endpoint allowed_ips handshake rx tx keepalive; do
    # Calculate time since last handshake
    if [ "$handshake" != "0" ]; then
        now=$(date +%s)
        handshake_age=$((now - handshake))
    else
        handshake_age="0"
    fi

    # Sanitize values for Prometheus labels
    endpoint_clean=$(echo "$endpoint" | sed 's/[^a-zA-Z0-9.:-]/_/g')
    allowed_ips_clean=$(echo "$allowed_ips" | sed 's/[^a-zA-Z0-9.,:/]/_/g')

    # Export peer info
    echo "wireguard_peer_info{interface=\"$WG_INTERFACE\",public_key=\"$pubkey\",endpoint=\"$endpoint_clean\",allowed_ips=\"$allowed_ips_clean\"} 1" >> "$TEMP_FILE"

    # Export latest handshake
    echo "wireguard_peer_latest_handshake_seconds{interface=\"$WG_INTERFACE\",public_key=\"$pubkey\"} $handshake_age" >> "$TEMP_FILE"

    # Export transfer stats
    echo "wireguard_peer_transfer_bytes_total{interface=\"$WG_INTERFACE\",public_key=\"$pubkey\",direction=\"rx\"} $rx" >> "$TEMP_FILE"
    echo "wireguard_peer_transfer_bytes_total{interface=\"$WG_INTERFACE\",public_key=\"$pubkey\",direction=\"tx\"} $tx" >> "$TEMP_FILE"

    # Export keepalive
    if [ "$keepalive" != "off" ] && [ "$keepalive" != "0" ]; then
        echo "wireguard_peer_keepalive_interval_seconds{interface=\"$WG_INTERFACE\",public_key=\"$pubkey\"} $keepalive" >> "$TEMP_FILE"
    fi
done

# Atomic move to prevent node_exporter from reading partial file
mv "$TEMP_FILE" "$OUTPUT_FILE"
