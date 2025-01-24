#!/bin/sh

# Check if a jail name is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <jail_name|all> [release]"
    exit 1
fi

TARGET=$1
RELEASE=$2

# Get the host's release without the patch level if not provided
if [ -z "$RELEASE" ]; then
    RELEASE=$(freebsd-version -u | cut -d'-' -f1-2)
    echo "No release specified. Using host release: $RELEASE"
else
    echo "Using specified release: $RELEASE"
fi

# Function to upgrade a single jail
upgrade_jail() {
    JAIL_NAME=$1
    JAIL_PATH="/usr/local/bastille/jails/$JAIL_NAME"

    if [ ! -d "$JAIL_PATH" ]; then
        echo "Jail $JAIL_NAME does not exist. Skipping."
        return
    fi

    echo -n "-- $JAIL_NAME: "
    if grep -q osrelease "$JAIL_PATH/jail.conf" 2>/dev/null; then
        echo "Thin jail"
    else
        echo "Thick jail"
    fi

    # Update and upgrade packages in the jail
    echo "Updating packages in jail $JAIL_NAME..."
    yes | sudo bastille pkg "$JAIL_NAME" update -f
    sudo bastille pkg "$JAIL_NAME" upgrade -y

    # Bootstrap and update the base release
    echo "Bootstrapping and upgrading release $RELEASE for jail $JAIL_NAME..."
    sudo bastille bootstrap "$RELEASE" update

    # Upgrade the jail to the specified or host release
    echo "Upgrading jail $JAIL_NAME to $RELEASE..."
    sudo bastille upgrade "$JAIL_NAME" "$RELEASE"
    sudo bastille upgrade "$JAIL_NAME" install

    # Restart the jail
    echo "Restarting jail $JAIL_NAME..."
    sudo bastille stop "$JAIL_NAME"
    sudo bastille start "$JAIL_NAME"

    # Finalize upgrade by re-installing base updates
    echo "Finalizing upgrade for jail $JAIL_NAME..."
    sudo bastille upgrade "$JAIL_NAME" install

    # Final package update and upgrade
    echo "Performing final package update and upgrade for jail $JAIL_NAME..."
    yes | sudo bastille pkg "$JAIL_NAME" update -f
    sudo bastille pkg "$JAIL_NAME" upgrade -y

    echo "Jail $JAIL_NAME has been updated and upgraded to release $RELEASE."
}

# Process all or a specific jail
if [ "$TARGET" = "all" ]; then
    echo "Upgrading all jails..."
    JAILS=$(bastille list jail)
else
    JAILS=$TARGET
fi

for JAIL in $JAILS; do
    upgrade_jail "$JAIL"
done

echo "All specified jails have been upgraded to release $RELEASE."

return 0
