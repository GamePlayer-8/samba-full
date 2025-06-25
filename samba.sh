#!/usr/bin/env bash

# Workaround for OpenRC patching, help wanted
#set -Eeuo pipefail


# This function checks for the existence of a specified Samba user and group. If the user does not exist, 
# it creates a new user with the provided username, user ID (UID), group name, group ID (GID), and password. 
# If the user already exists, it updates the user's UID and group association as necessary, 
# and updates the password in the Samba database. The function ensures that the group also exists, 
# creating it if necessary, and modifies the group ID if it differs from the provided value.
add_user() {
    local cfg="$1"
    local username="$2"
    local uid="$3"
    local groupname="$4"
    local gid="$5"
    local password="$6"
    local homedir="$7"

    # Check if the smb group exists, if not, create it
    if ! getent group "$groupname" &>/dev/null; then
        [[ "$groupname" != "smb" ]] && echo "Group $groupname does not exist, creating group..."
        groupadd -o -g "$gid" "$groupname" > /dev/null || { echo "Failed to create group $groupname"; return 1; }
    else
        # Check if the gid right,if not, change it
        local current_gid
        current_gid=$(getent group "$groupname" | cut -d: -f3)
        if [[ "$current_gid" != "$gid" ]]; then
            [[ "$groupname" != "smb" ]] && echo "Group $groupname exists but GID differs, updating GID..."
            groupmod -o -g "$gid" "$groupname" > /dev/null || { echo "Failed to update GID for group $groupname"; return 1; }
        fi
    fi

    # Check if the user already exists, if not, create it
    if ! id "$username" &>/dev/null; then
        [[ "$username" != "$USER" ]] && echo "User $username does not exist, creating user..."
        extra_args=()
        # Check if home directory already exists, if so do not create home during user creation
        if [ -d "$homedir" ]; then
          extra_args=("${extra_args[@]}" -H)
        fi
        adduser "${extra_args[@]}" -S -D -h "$homedir" -s /sbin/nologin -G "$groupname" -u "$uid" -g "Samba User" "$username" || { echo "Failed to create user $username"; return 1; }
    else
        # Check if the uid right,if not, change it
        local current_uid
        current_uid=$(id -u "$username")
        if [[ "$current_uid" != "$uid" ]]; then
            echo "User $username exists but UID differs, updating UID..."
            usermod -o -u "$uid" "$username" > /dev/null || { echo "Failed to update UID for user $username"; return 1; }
        fi

        # Update user's group
        usermod -g "$groupname" "$username" > /dev/null || { echo "Failed to update group for user $username"; return 1; }
    fi

    # Check if the user is a samba user
    pdb_output=$(pdbedit -s "$cfg" -L)  #Do not combine the two commands into one, as this could lead to issues with the execution order and proper passing of variables. 
    if echo "$pdb_output" | grep -q "^$username:"; then
        # skip samba password update if password is * or !
        if [[ "$password" != "*" && "$password" != "!" ]]; then
            # If the user is a samba user, update its password in case it changed
            echo -e "$password\n$password" | smbpasswd -c "$cfg" -s "$username" > /dev/null || { echo "Failed to update Samba password for $username"; return 1; }
        fi
    else
        # If the user is not a samba user, create it and set a password
        echo -e "$password\n$password" | smbpasswd -a -c "$cfg" -s "$username" > /dev/null || { echo "Failed to add Samba user $username"; return 1; }
        [[ "$username" != "$USER" ]] && echo "User $username has been added to Samba and password set."
    fi

    return 0
}

# Set variables for group and share directory
group="smb"
share="/storage"
secret="/run/secrets/pass"
config="/etc/samba/smb.conf"
users="/etc/samba/users.conf"

# Create shared directory
mkdir -p "$share" || { echo "Failed to create directory $share"; exit 1; }

# Check if the secret file exists and if its size is greater than zero
if [ -s "$secret" ]; then
    PASS=$(cat "$secret")
fi

# Check if config file is not a directory
if [ -d "$config" ]; then

    echo "The bind $config maps to a file that does not exist!"
    exit 1

fi

# Check if an external config file was supplied
if [ -f "$config" ] && [ -s "$config" ]; then

    # Inform the user we are using a custom configuration file.
    echo "Using provided configuration file: $config."

else

    config="/etc/samba/smb.tmp"
    template="/etc/samba/smb.default"

    if [ ! -f "$template" ]; then
      echo "Your /etc/samba directory does not contain a valid smb.conf file!"
      exit 1
    fi

    # Generate a config file from template
    rm -f "$config"
    cp "$template" "$config"

    # Set custom display name if provided
    if [ -n "$NAME" ] && [[ "${NAME,,}" != "data" ]]; then
      sed -i "s/\[Data\]/\[$NAME\]/" "$config"    
    fi

    # Update force user and force group in smb.conf
    sed -i "s/^\(\s*\)force user =.*/\1force user = $USER/" "$config"
    sed -i "s/^\(\s*\)force group =.*/\1force group = $group/" "$config"

    # Verify if the RW variable is equal to false (indicating read-only mode) 
    if [[ "$RW" == [Ff0]* ]]; then
        # Adjust settings in smb.conf to set share to read-only
        sed -i "s/^\(\s*\)writable =.*/\1writable = no/" "$config"
        sed -i "s/^\(\s*\)read only =.*/\1read only = yes/" "$config"
    fi

fi

# Check if users file is not a directory
if [ -d "$users" ]; then

    echo "The file $users does not exist, please check that you mapped it to a valid path!"
    exit 1

fi

# Create directories if missing
mkdir -p /var/lib/samba/sysvol
mkdir -p /var/lib/samba/private
mkdir -p /var/lib/samba/bind-dns

# Check if multi-user mode is enabled
if [ -f "$users" ] && [ -s "$users" ]; then

    while IFS= read -r line || [[ -n ${line} ]]; do

        # Skip lines that are comments or empty
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue

        # Split each line by colon and assign to variables
        IFS=':' read -r username uid groupname gid password homedir <<< "$line"

        # Check if all required fields are present
        if [[ -z "$username" || -z "$uid" || -z "$groupname" || -z "$gid" || -z "$password" ]]; then
            echo "Skipping incomplete line: $line"
            continue
        fi

        # Default homedir if not explicitly set for user
        [[ -z "$homedir" ]] && homedir="$share"

        # Call the function with extracted values
        add_user "$config" "$username" "$uid" "$groupname" "$gid" "$password" "$homedir" || { echo "Failed to add user $username"; exit 1; }

    done < <(tr -d '\r' < "$users")

else

    add_user "$config" "$USER" "$UID" "$group" "$GID" "$PASS" "$share" || { echo "Failed to add user $USER"; exit 1; }

    if [[ "$RW" != [Ff0]* ]]; then
        # Set permissions for share directory if new (empty), leave untouched if otherwise
        if [ -z "$(ls -A "$share")" ]; then
            chmod 0770 "$share" || { echo "Failed to set permissions for directory $share"; exit 1; }
            chown "$USER:$group" "$share" || { echo "Failed to set ownership for directory $share"; exit 1; }
        fi
    fi

fi

# Store configuration location for Healthcheck
ln -sf "$config" /etc/samba.conf

# Set directory permissions
[ -d /run/samba/msg.lock ] && chmod -R 0755 /run/samba/msg.lock
[ -d /var/log/samba/cores ] && chmod -R 0700 /var/log/samba/cores
[ -d /var/cache/samba/msg.lock ] && chmod -R 0755 /var/cache/samba/msg.lock

# Start the Samba daemons with the following options:
#  --configfile: Location of the configuration file.
#  --foreground: Run in the foreground instead of daemonizing.
#  --debug-stdout: Send debug output to stdout.
#  --debuglevel=1: Set debug verbosity level to 1.
#  --no-process-group: Don't create a new process group for the daemon.

startUp() {
    exec "$1" --configfile="$config" --foreground --debug-stdout --debuglevel=1 --no-process-group &
    eval "export ${1}_pid=$!"
}

# Start each daemon in order as it is in OpenRC Alpine configuration
for daemon in $DAEMON_LIST; do
    startUp "$daemon"
done

# WSDD daemon runtime based upon OpenRC config
startWsdd() {

    if [ -z "$WSDD_OPTS" ]; then
        WSDD_OPTS="-i 0.0.0.0 -i ::/0"
    fi

    if [ -z "$WSDD_LOG_FILE" ]; then
        WSDD_LOG_FILE="/var/log/wsdd.log"
    fi

    if [ -z "$WSDD_WORKGROUP" ]; then
        # try to extract workgroup with Samba's testparm
        if which testparm >/dev/null 2>/dev/null; then
            GROUP="$(testparm -s --parameter-name workgroup 2>/dev/null)"
        fi

        # fallback to poor man's approach if testparm is unavailable or failed for some reason
        if [ -z "$GROUP" ] && [ -r "$config" ]; then
            GROUP=`grep -i '^\s*workgroup\s*=' "$config" | cut -f2 -d= | tr -d '[:blank:]'`
        fi

        if [ -n "${GROUP}" ]; then
            WSDD_OPTS="-w ${GROUP} ${WSDD_OPTS}"
        fi
    else
        WSDD_OPTS="-w ${WSDD_WORKGROUP} ${WSDD_OPTS}"
    fi

    if [ ! -r "${WSDD_LOG_FILE}" ]; then
        touch "${WSDD_LOG_FILE}"
    fi
    chown wsdd:wsdd "${WSDD_LOG_FILE}"

    start-stop-daemon --start --background --user wsdd:wsdd --make-pidfile --pidfile /var/run/wsdd.pid --stdout "${WSDD_LOG_FILE}" --stderr "${WSDD_LOG_FILE}" --exec /usr/bin/wsdd -- ${WSDD_OPTS}

    return $?
}

# Whenever WSDD is enabled on boot
if [ "$WSDD" = "1" ]; then
    startWsdd
fi

# Workaround for DBus to have unique machine ID
generateMachineID() {
    # If machine-id is already predefined - pass
    if [ -s /etc/machine-id ] ; then
        return 0
    fi

    dd if=/dev/random status=none bs=16 count=1 \
        | md5sum | cut -d' ' -f1 > /etc/machine-id
    return $?
}

# DBus runtime
startDBUS() {
    generateMachineID
    install -m755 -o root -g messagebus -d /run/dbus || return 1

    /usr/bin/dbus-uuidgen --ensure="${machine_id:-/etc/machine-id}"

    /usr/bin/dbus-daemon --system --fork --nopidfile --nosyslog
}

# Avahi runtime with hostname patches
startAvahi() {
    hostname=`grep -i '^\s*server string\s*=' "$config" | cut -f2 -d= | tr -d '[:blank:]'`
    echo "$hostname" > /etc/hostname
    startDBUS
    /usr/sbin/avahi-daemon -D
    return $?
}

# Avahi
if [ "$AVAHI" = "1" ]; then
    startAvahi
fi

eval "wait \$$(echo "$DAEMON_LIST" | cut -f1 -d ' ')_pid" # Workaround to daemonize shell script
