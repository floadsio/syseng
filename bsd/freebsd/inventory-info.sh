#!/bin/sh
# inventory-info.sh — FreeBSD inventory (ZFS + ARC aware)
set -eu

have() { command -v "$1" >/dev/null 2>&1; }
fmt_mb()  { awk 'BEGIN{b='"${1:-0}"'; printf "%d MB", b/1024/1024}'; }
fmt_gb1() { awk 'BEGIN{b='"${1:-0}"'; printf "%.1f GB", b/1024/1024/1024}'; }

VENDOR=N/A MODEL=N/A PRODUCT=N/A SERIAL=N/A UUID=N/A
CPU_MODEL=N/A CPU_CORES=N/A CPU_SPEED=N/A
DISKS=N/A NICS=N/A MEMORY=N/A COMS=N/A ZPOOLS=N/A ARC=N/A SUMMARY=N/A

if have dmidecode; then
  VENDOR="$(dmidecode -s system-manufacturer 2>/dev/null || echo N/A)"
  MODEL="$(dmidecode -s system-version 2>/dev/null || echo N/A)"
  PRODUCT="$(dmidecode -s system-product-name 2>/dev/null || echo N/A)"
  SERIAL="$(dmidecode -s system-serial-number 2>/dev/null || echo N/A)"
  UUID="$(dmidecode -s system-uuid 2>/dev/null || echo N/A)"
else
  MODEL="$(sysctl -n hw.model 2>/dev/null || echo N/A)"
  UUID="$(sysctl -n kern.hostuuid 2>/dev/null || echo N/A)"
fi

CPU_MODEL="$(sysctl -n hw.model 2>/dev/null || echo N/A)"
CPU_CORES="$(sysctl -n hw.ncpu 2>/dev/null || echo N/A)"
CPU_SPEED="$(sysctl -n hw.clockrate 2>/dev/null || echo N/A) MHz"

pmem="$(sysctl -n hw.physmem 2>/dev/null || echo 0)"
MEMORY="$(fmt_mb "$pmem")"

out=""; biggest=0; summarydisk="N/A"
if have camcontrol; then
  while IFS= read -r line; do
    model=$(echo "$line" | sed -n 's/.*<\([^>]*\)>.*/\1/p')
    dev=$(echo "$line" | sed -n 's/.*(\([^,)]*\).*/\1/p')
    [ -z "$dev" ] && continue
    size="N/A"; bytes=0
    if have diskinfo && diskinfo -v "/dev/$dev" >/dev/null 2>&1; then
      bytes=$(diskinfo -v "/dev/$dev" | awk '/mediasize in bytes/ {print $5}')
      [ -n "$bytes" ] && [ "$bytes" -gt 0 ] 2>/dev/null && size="$(fmt_gb1 "$bytes")"
      [ "$bytes" -gt "$biggest" ] 2>/dev/null && biggest="$bytes"
    fi
    out="${out:+$out, }$dev=$model ($size)"
  done <<EOF
$(camcontrol devlist 2>/dev/null)
EOF
fi
[ -n "$out" ] && DISKS="$out" || DISKS="N/A"
[ "$biggest" -gt 0 ] 2>/dev/null && summarydisk="$(fmt_gb1 "$biggest")"

out=""
for nic in $(ifconfig -l 2>/dev/null | tr ' ' '\n'); do
  case "$nic" in em*|igb*|ix*|ixl*|re*|bge*|alc*|ale*|bce*|mlxen*)
    mac="$(ifconfig "$nic" 2>/dev/null | awk '/ether[[:space:]]/ {print $2; exit}')"
    [ -n "$mac" ] && out="${out:+$out, }$nic=$mac"
  ;;
  esac
done
NICS="${out:-N/A}"

COMS="$(dmesg 2>/dev/null | awk '/^uart[0-9]+:/ {gsub(":","",$1); if(!seen[$1]++){ if(out!="") out=out", "; out=out $1 }} END{ print (out!=""?out:"N/A") }')"

if have zpool; then
  ZPOOLS="$(zpool list -H -o name,size,alloc,free,health 2>/dev/null | awk '{printf "%s%s(size=%s, alloc=%s, free=%s, %s)",(NR>1?", ":""),$1,$2,$3,$4,$5} END{if(NR==0) print "N/A"}')"
fi

arc_cur="$(sysctl -n kstat.zfs.misc.arcstats.size 2>/dev/null || sysctl -n vfs.zfs.arc_size 2>/dev/null || echo 0)"
arc_max="$(sysctl -n kstat.zfs.misc.arcstats.c_max 2>/dev/null || sysctl -n vfs.zfs.arc_max 2>/dev/null || echo 0)"
if [ "${arc_cur:-0}" -gt 0 ] 2>/dev/null; then
  cur_disp="$(fmt_gb1 "$arc_cur")"
  if [ "${arc_max:-0}" -gt 0 ] 2>/dev/null; then max_disp="$(fmt_gb1 "$arc_max")"; else max_disp="auto"; fi
  ARC="current=${cur_disp}, max=${max_disp}"
fi

mem_gb="$(echo "$pmem" | awk '{printf "%.0f",$1/1024/1024/1024}')"
SUMMARY="$CPU_MODEL / ${mem_gb}GB RAM / ${summarydisk}"

printf "Vendor: %s | Model: %s | Product No: %s | Serial: %s | UUID: %s\n" "$VENDOR" "$MODEL" "$PRODUCT" "$SERIAL" "$UUID"
echo "CPU: $CPU_MODEL, $CPU_CORES cores @ $CPU_SPEED"
echo "Disks: $DISKS"
echo "NICs: $NICS"
echo "Memory: $MEMORY"
echo "COM ports: $COMS"
echo "ZFS pools: $ZPOOLS"
echo "ARC: $ARC"
echo "Summary: $SUMMARY"