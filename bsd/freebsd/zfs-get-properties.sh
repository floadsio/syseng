#!/bin/sh

props=$(zfs get -H -o property all | grep ':' | sort -u)
echo_commands=""

for prop in $props; do
  echo "== $prop =="
  zfs get -H -o name,value,source "$prop" | awk -v p="$prop" '
    $3 != "-" {
      print $1, $2, $3
      if ($3 == "local") {
        printf("zfs inherit %s %s\n", p, $1) >> "/tmp/zfs_inherit_cmds"
      }
    }
  '
  echo ""
done

if [ -f /tmp/zfs_inherit_cmds ]; then
  echo "== Commands to remove locally set properties =="
  cat /tmp/zfs_inherit_cmds
  rm /tmp/zfs_inherit_cmds
else
  echo "No locally set properties to remove."
fi
