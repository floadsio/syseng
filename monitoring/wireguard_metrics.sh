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

# Parse wg show dump output using awk for better portability
# Format: peer-public-key preshared-key endpoint allowed-ips latest-handshake transfer-rx transfer-tx persistent-keepalive

wg show "$WG_INTERFACE" dump | tail -n +2 | awk -F'\t' -v interface="$WG_INTERFACE" '
{
    pubkey = $1
    endpoint = $3
    allowed_ips = $4
    handshake = $5
    rx = $6
    tx = $7
    keepalive = $8

    # Calculate time since last handshake
    if (handshake != "0") {
        "date +%s" | getline now
        close("date +%s")
        handshake_age = now - handshake
    } else {
        handshake_age = 0
    }

    # Sanitize values for Prometheus labels
    gsub(/[^a-zA-Z0-9.:-]/, "_", endpoint)
    gsub(/[^a-zA-Z0-9.,:/]/, "_", allowed_ips)

    # Export peer info
    print "wireguard_peer_info{interface=\"" interface "\",public_key=\"" pubkey "\",endpoint=\"" endpoint "\",allowed_ips=\"" allowed_ips "\"} 1"

    # Export latest handshake
    print "wireguard_peer_latest_handshake_seconds{interface=\"" interface "\",public_key=\"" pubkey "\"} " handshake_age

    # Export transfer stats
    print "wireguard_peer_transfer_bytes_total{interface=\"" interface "\",public_key=\"" pubkey "\",direction=\"rx\"} " rx
    print "wireguard_peer_transfer_bytes_total{interface=\"" interface "\",public_key=\"" pubkey "\",direction=\"tx\"} " tx

    # Export keepalive
    if (keepalive != "off" && keepalive != "0") {
        print "wireguard_peer_keepalive_interval_seconds{interface=\"" interface "\",public_key=\"" pubkey "\"} " keepalive
    }
}' >> "$TEMP_FILE"

# Atomic move to prevent node_exporter from reading partial file
mv "$TEMP_FILE" "$OUTPUT_FILE"
