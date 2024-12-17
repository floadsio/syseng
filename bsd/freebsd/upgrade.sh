#!/bin/sh

echo "kernel: $(freebsd-version -k)"
echo "userland: $(freebsd-version -u)"

echo -e "\nsudo freebsd-update fetch
sudo freebsd-update install

sudo pkg update
sudo pkg upgrade
"

echo "sudo freebsd-update -r 14.0-RELEASE upgrade"
echo "sudo /usr/sbin/freebsd-update install"

echo -e "\nOnce done:\n
Installing updates...
Kernel updates have been installed.  Please reboot and run
"/usr/sbin/freebsd-update install" again to finish installing updates."
