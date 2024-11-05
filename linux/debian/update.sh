#!/bin/sh

# Update packages without restarting services

DEBIAN_FRONTEND=noninteractive \
    apt-get -o Dpkg::Options::="--force-confold" \
    -o Dpkg::Options::="--force-confdef" \
    -o DPkg::options::="--force-confnew" dist-upgrade -y $1

DEBIAN_FRONTEND=noninteractive \
    apt-get -o Dpkg::Options::="--force-confold" \
    -o Dpkg::Options::="--force-confdef" \
    -o DPkg::options::="--force-confnew" auto-remove -y $1
