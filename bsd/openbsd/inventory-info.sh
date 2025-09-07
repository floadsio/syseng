#!/bin/sh
# inventory-info.sh — OpenBSD inventory
set -eu

fmt_mb()  { awk 'BEGIN{b='"${1:-0}"'; printf "%d MB", b/1024/1024}'; }

VENDOR="$(sysctl -n hw.vendor 2>/dev/null || echo N/A)"
PRODUCT="$(sysctl -n hw.product 2>/dev/null || echo N/A)"
VERSION="$(sysctl -n hw.version 2>/dev/null || echo "")"
SERIAL="$(sysctl -n hw.serialno 2>/dev/null || echo N/A)"
# Try variant (e.g., apu4c4) from bios0:
MODEL="$( (dmesg 2>/dev/null | grep '^bios0:' | grep -o 'apu[0-9][a-z0-9]*' | head -n1) || true )"
[ -z "${MODEL:-}" ] && MODEL="${PRODUCT}${VERSION:+ ${VERSION}}"
UUID="N/A"

CPU_MODEL="$(sysctl -n hw.model 2>/dev/null || echo N/A)"
CPU_CORES="$(sysctl -n hw.ncpufound 2>/dev/null || echo N/A)"
CPU_SPEED="$(sysctl -n hw.cpuspeed 2>/dev/null || echo N/A) MHz"

pmem="$(sysctl -n hw.physmem 2>/dev/null || echo 0)"
MEMORY="$(fmt_mb "$pmem")"

DISKS="$(dmesg 2>/dev/null | awk '/^[swd]d[0-9]+:/ {gsub(":","",$1); s=$2; gsub(",","",s); if(s ~ /MB|GB/){ if(out!="") out=out", "; out=out $1"="s }} END{print (out!=""?out:"N/A")}')"

out=""
for nic in $(ifconfig -l 2>/dev/null | tr ' ' '\n'); do
  case "$nic" in lo*|enc*|pflog*|pfsync*|bridge*|vlan*|trunk*|carp*|wg*|tun*|tap*|gif*|gre*|vether*|vport*|pppoe*) continue;;
  esac
  mac="$(ifconfig "$nic" 2>/dev/null | awk '/lladdr/ {print $2; exit}')"
  [ -n "$mac" ] || continue
  out="${out:+$out, }${nic}=${mac}"
done
NICS="${out:-N/A}"

COMS="$(dmesg 2>/dev/null | awk '/^com[0-9]+ at/ {gsub(":","",$1); if(!seen[$1]++){ if(out!="") out=out", "; out=out $1 }} END{ print (out!=""?out:"N/A") }')"

ZPOOLS="N/A"; ARC="N/A"
mem_gb="$(echo "$pmem" | awk '{printf "%.0f",$1/1024/1024/1024}')"
SUMMARY="$CPU_MODEL / ${mem_gb}GB RAM / ${DISKS}"

printf "Vendor: %s | Model: %s | Product No: %s | Serial: %s | UUID: %s\n" "$VENDOR" "$MODEL" "$PRODUCT" "$SERIAL" "$UUID"
echo "CPU: $CPU_MODEL, $CPU_CORES cores @ $CPU_SPEED"
echo "Disks: $DISKS"
echo "NICs: $NICS"
echo "Memory: $MEMORY"
echo "COM ports: $COMS"
echo "ZFS pools: $ZPOOLS"
echo "ARC: $ARC"
echo "Summary: $SUMMARY"