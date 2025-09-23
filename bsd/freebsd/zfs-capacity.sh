#!/bin/sh

# Check if argument provided, default to zroot if not
DATASET=${1:-zroot}

# Strip leading slash if present (zfs doesn't use it)
DATASET=$(echo "$DATASET" | sed 's|^/||')

# Get used/available and calculate percentage
zfs list -H -p -o used,avail "$DATASET" 2>/dev/null | {
    read used avail
    if [ -n "$used" ] && [ -n "$avail" ]; then
        echo $((used * 100 / (used + avail)))
    else
        echo "Dataset not found: $DATASET" >&2
        exit 1
    fi
}
