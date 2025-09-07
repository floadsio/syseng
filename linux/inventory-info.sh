#!/bin/sh
# inventory-info.sh — Linux (generic) + OpenWrt (new & old)
set -eu

have() { command -v "$1" >/dev/null 2>&1; }
fmt_mb()  { awk 'BEGIN{b='"${1:-0}"'; printf "%d MB", b/1024/1024}'; }
fmt_gb1() { awk 'BEGIN{b='"${1:-0}"'; printf "%.1f GB", b/1024/1024/1024}'; }

OS="$(uname -s 2>/dev/null || echo Linux)"

VENDOR=N/A MODEL=N/A PRODUCT=N/A SERIAL=N/A UUID=N/A
CPU_MODEL=N/A CPU_CORES=N/A CPU_SPEED=N/A
DISKS=N/A NICS=N/A MEMORY=N/A COMS=N/A ZPOOLS=N/A ARC=N/A SUMMARY=N/A

is_openwrt=false
if [ -f /etc/openwrt_release ] || ( [ -f /etc/os-release ] && grep -qi openwrt /etc/os-release ); then
  is_openwrt=true
fi

if $is_openwrt; then
  # -------- OpenWrt --------
  if have ubus && have jsonfilter; then
    MODEL="$(ubus call system board 2>/dev/null | jsonfilter -e '@.model' || true)"
    PRODUCT="$(ubus call system board 2>/dev/null | jsonfilter -e '@.board_name' || true)"
  fi
  [ -z "${MODEL:-}" ]   && [ -f /tmp/sysinfo/model ]      && MODEL="$(cat /tmp/sysinfo/model)"
  [ -z "${PRODUCT:-}" ] && [ -f /tmp/sysinfo/board_name ] && PRODUCT="$(cat /tmp/sysinfo/board_name)"
  VENDOR="$(echo "$MODEL" | awk '{print $1}')" || VENDOR="OpenWrt"
  SERIAL="$(cat /sys/firmware/devicetree/base/serial-number 2>/dev/null || true)"
  [ -z "${SERIAL:-}" ] && SERIAL="$(awk -F: '/^Serial/ {gsub(/^[ \t]+/,"",$2); print $2}' /proc/cpuinfo 2>/dev/null || true)"
  [ -z "${SERIAL:-}" ] && SERIAL=N/A
  UUID="$(cat /sys/class/dmi/id/product_uuid 2>/dev/null || echo N/A)"

  CPU_MODEL="$(awk -F: '/model name|system type|cpu model/ {gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || echo N/A)"
  CPU_CORES="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)"
  CPU_SPEED="$(awk -F: '/cpu MHz/ {mhz=$2} END{gsub(/^[ \t]+/,"",mhz); if(mhz!="") printf "%.0f MHz", mhz; else print "N/A"}' /proc/cpuinfo 2>/dev/null)"

  mem_kb="$(awk '/MemTotal/ {print $2*1024}' /proc/meminfo 2>/dev/null || echo 0)"
  MEMORY="$(fmt_mb "$mem_kb")"

  if df -h /overlay >/dev/null 2>&1; then
    OVER="$(df -h /overlay | awk 'NR==2 {print $2" total, "$4" free"}')"
  else
    OVER="$(df -h / | awk 'NR==2 {print $2" total, "$4" free"}')"
  fi

  out=""; biggest=0; SUMMARYDISK="overlay"
  for b in /sys/block/*; do
    base="$(basename "$b")"
    case "$base" in sd*|mmcblk*|nvme*) :;; *) continue;; esac
    sectors="$(cat "$b/size" 2>/dev/null || echo 0)"; bytes=$((sectors * 512))
    size_h="$(fmt_gb1 "$bytes")"
    label="$(printf "%s %s" "$(cat "$b/device/vendor" 2>/dev/null)" "$(cat "$b/device/model" 2>/dev/null)" | sed 's/[[:space:]]\+$//')"
    [ -z "$label" ] && label="(block)"
    out="${out:+$out, }$base=$label (${size_h})"
    [ "$bytes" -gt "$biggest" ] 2>/dev/null && biggest="$bytes" && SUMMARYDISK="$(fmt_gb1 "$bytes")"
  done
  DISKS="${out:-overlay=$OVER}"; [ "$DISKS" = "overlay=$OVER" ] && SUMMARYDISK="overlay"

  out=""
  for p in /sys/class/net/*; do
    i="$(basename "$p")"
    case "$i" in lo|br*|bond*|vlan*|gre*|gretap*|erspan*|sit*|ip6tnl*|veth*|docker*|wg*|pppoe*|ifb*|bat*|bridge*|*.*|*@*) continue;;
    esac
    case "$i" in eth*|wlan*|lan*|wan*) mac="$(cat "/sys/class/net/$i/address" 2>/dev/null)"; [ -n "$mac" ] && out="${out:+$out, }$i=$mac";;
    esac
  done
  NICS="${out:-N/A}"

  COMS="$(dmesg 2>/dev/null | sed -n 's/.*\(ttyS[0-9]\+\).*/\1/p' | awk '!seen[$0]++' | paste -sd ', ' - 2>/dev/null || true)"
  [ -n "${COMS:-}" ] || COMS="N/A"
  ZPOOLS="N/A"; ARC="N/A"

  mem_gb="$(echo "$mem_kb" | awk '{printf "%.0f",$1/1024/1024}')"
  SUMMARY="$CPU_MODEL / ${mem_gb}GB RAM / ${SUMMARYDISK}"

else
  # -------- Generic Linux --------
  VENDOR="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo N/A)"
  MODEL="$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo N/A)"
  PRODUCT="$(cat /sys/class/dmi/id/product_family 2>/dev/null || echo N/A)"
  SERIAL="$(cat /sys/class/dmi/id/product_serial 2>/dev/null || echo N/A)"
  UUID="$(cat /sys/class/dmi/id/product_uuid 2>/dev/null || cat /etc/machine-id 2>/dev/null || echo N/A)"

  CPU_MODEL="$(awk -F: '/model name/ {gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || echo N/A)"
  CPU_CORES="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)"
  CPU_SPEED="$(awk -F: '/cpu MHz/ {mhz=$2} END{gsub(/^[ \t]+/,"",mhz); if(mhz!="") printf "%.0f MHz", mhz; else print "N/A"}' /proc/cpuinfo 2>/dev/null)"

  mem_kb="$(awk '/MemTotal/ {print $2*1024}' /proc/meminfo 2>/dev/null || echo 0)"
  MEMORY="$(fmt_mb "$mem_kb")"

  out=""; biggest=0; summarydisk="N/A"
  if command -v lsblk >/dev/null 2>&1; then
    while IFS= read -r dev; do
      size="$(lsblk -dn -o SIZE "/dev/$dev" 2>/dev/null || echo N/A)"
      model="$(lsblk -dn -o MODEL "/dev/$dev" 2>/dev/null || echo)"
      out="${out:+$out, }$dev=$model ($size)"
      bs="$(lsblk -nb -o SIZE -d "/dev/$dev" 2>/dev/null || echo 0)"
      [ "$bs" -gt "$biggest" ] 2>/dev/null && biggest="$bs"
    done <<EOF
$(lsblk -dno NAME 2>/dev/null)
EOF
  else
    for b in /sys/block/*; do
      dev="$(basename "$b")"
      case "$dev" in sd*|nvme*|vd*|hd*|xvd*) :;; *) continue;; esac
      sectors="$(cat "$b/size" 2>/dev/null || echo 0)"; bytes=$((sectors*512))
      size_h="$(fmt_gb1 "$bytes")"
      label="$(printf "%s %s" "$(cat "$b/device/vendor" 2>/dev/null)" "$(cat "$b/device/model" 2>/dev/null)" | sed 's/[[:space:]]\+$//')"
      [ -z "$label" ] && label="(disk)"
      out="${out:+$out, }$dev=$label ($size_h)"
      [ "$bytes" -gt "$biggest" ] 2>/dev/null && biggest="$bytes"
    done
  fi
  DISKS="${out:-N/A}"; [ "$biggest" -gt 0 ] 2>/dev/null && summarydisk="$(fmt_gb1 "$biggest")"

  out=""
  for p in /sys/class/net/*; do
    i="$(basename "$p")"
    case "$i" in lo|br*|bond*|veth*|docker*|tun*|tap*|wg*|virbr*|nm-*) continue;; esac
    mac="$(cat "/sys/class/net/$i/address" 2>/dev/null)"
    [ -n "$mac" ] && out="${out:+$out, }$i=$mac"
  done
  NICS="${out:-N/A}"

  COMS="$(dmesg 2>/dev/null | sed -n 's/.*\(ttyS[0-9]\+\).*/\1/p' | awk '!seen[$0]++' | paste -sd ', ' - 2>/dev/null || true)"
  [ -n "${COMS:-}" ] || COMS="N/A"

  if command -v zpool >/dev/null 2>&1; then
    ZPOOLS="$(zpool list -H -o name,size,alloc,free,health 2>/dev/null | awk '{printf "%s%s(size=%s, alloc=%s, free=%s, %s)",(NR>1?", ":""),$1,$2,$3,$4,$5} END{if(NR==0) print "N/A"}')"
  fi
  ARC="N/A"

  mem_gb="$(echo "$mem_kb" | awk '{printf "%.0f",$1/1024/1024}')"
  SUMMARY="$CPU_MODEL / ${mem_gb}GB RAM / ${summarydisk}"
fi

printf "Vendor: %s | Model: %s | Product No: %s | Serial: %s | UUID: %s\n" "$VENDOR" "$MODEL" "$PRODUCT" "$SERIAL" "$UUID"
echo "CPU: $CPU_MODEL, $CPU_CORES cores @ $CPU_SPEED"
echo "Disks: $DISKS"
echo "NICs: $NICS"
echo "Memory: $MEMORY"
echo "COM ports: $COMS"
echo "ZFS pools: $ZPOOLS"
echo "ARC: $ARC"
echo "Summary: $SUMMARY"