#!/bin/ash
# Define variables
WWAN_IFACE="rmnet_mhi0.1"
PING_INTERVAL=5  # Seconds between pings
FAIL_THRESHOLD=30  # Number of consecutive failures before restarting module (100s total)
QUECTEL_TOOLS="quectel-CM-M quectel-CM quectel-cm"  # Priority order of tools to try (space-separated)
QUECTEL_TOOL=""  # Will be set by detect_quectel_tool function
AT_CMD="AT+CFUN=1,1"  # Restart module AT command
DEVICE="/dev/mhi_DUN"  # Device interface for AT command
LOG_FILE="/tmp/modem-log.txt"
PING_TARGET="8.8.8.8"
FAIL_COUNT=0
UCI_INTERFACE_NAME="Modem"  # UCI interface name for configuration

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE" | logger
}

trap 'log_message "Script stopping. Killing all Quectel processes..."; kill_quectel_processes; exit 0' SIGINT SIGTERM

# Function to detect available Quectel tool
detect_quectel_tool() {
    for tool in $QUECTEL_TOOLS; do
        if command -v "$tool" >/dev/null 2>&1; then
            QUECTEL_TOOL="$tool"
            log_message "Detected available Quectel tool: $QUECTEL_TOOL"
            return 0
        fi
    done
    log_message "ERROR: No Quectel tool found! Tried: $QUECTEL_TOOLS"
    exit 1
}

# Function to start Quectel connection manager
start_quectel_cm() {
    log_message "Starting $QUECTEL_TOOL..."
    $QUECTEL_TOOL -4 -s m-wap -f /tmp/log.txt &
    sleep 2
}

# Function to kill all Quectel processes using killall
kill_quectel_processes() {
    local killed=0
    for tool in $QUECTEL_TOOLS; do
        if killall "$tool" 2>/dev/null; then
            log_message "Killed $tool processes"
            killed=1
        fi
    done
    [ $killed -eq 0 ] && log_message "No Quectel processes found to kill"
}

# Function to configure DHCP interface using UCI
configure_dhcp_interface() {
    log_message "Configuring DHCP interface for $WWAN_IFACE..."
    
    # Check if interface already exists
    if ! uci get network.$UCI_INTERFACE_NAME >/dev/null 2>&1; then
        log_message "Creating new UCI interface: $UCI_INTERFACE_NAME"
        uci set network.$UCI_INTERFACE_NAME=interface
    else
        log_message "UCI interface $UCI_INTERFACE_NAME already exists, updating configuration..."
    fi
    
    # Configure interface settings
    uci set network.$UCI_INTERFACE_NAME.proto='dhcp'
    
    # Try both 'device' and 'ifname' for compatibility
    uci set network.$UCI_INTERFACE_NAME.device="$WWAN_IFACE" 2>/dev/null
    uci set network.$UCI_INTERFACE_NAME.ifname="$WWAN_IFACE"
    
    uci set network.$UCI_INTERFACE_NAME.metric='10'
    uci set network.$UCI_INTERFACE_NAME.auto='1'
    
    # Commit network changes
    uci commit network
    
    # Add interface to WAN firewall zone
    log_message "Adding $UCI_INTERFACE_NAME to WAN firewall zone..."
    
    # Get current WAN zone networks
    wan_networks=$(uci get firewall.@zone[1].network 2>/dev/null)
    
    # Check if wwan is already in the list
    if echo "$wan_networks" | grep -qw "$UCI_INTERFACE_NAME"; then
        log_message "Interface $UCI_INTERFACE_NAME already in WAN zone"
    else
        # Add wwan to WAN zone
        uci add_list firewall.@zone[1].network="$UCI_INTERFACE_NAME"
        uci commit firewall
        log_message "Added $UCI_INTERFACE_NAME to WAN firewall zone"
        
        # Reload firewall
        /etc/init.d/firewall reload
    fi
    
    log_message "DHCP interface configured. Reloading network..."
    /etc/init.d/network reload
    
    sleep 5
    log_message "Network and firewall configuration completed."
}

# Function to check device availability
check_device() {
    while [ ! -e "$DEVICE" ]; do
        kill_quectel_processes
        echo 1 > /sys/bus/pci/rescan
        sleep 10
    done
}

# Function to check if interface is up
check_interface_up() {
    ip link show "$WWAN_IFACE" up >/dev/null 2>&1
}

# Ensure device is available before starting
check_device

# Detect and set the available Quectel tool
detect_quectel_tool

# Configure DHCP interface on startup
configure_dhcp_interface

while true; do
    check_device  # Continuously check if the device is still available
    
    # Check if interface is up, if not try to bring it up
    if ! check_interface_up; then
        log_message "Interface $WWAN_IFACE is down. Attempting to bring it up..."
        ip link set "$WWAN_IFACE" up 2>/dev/null
        ifup "$UCI_INTERFACE_NAME" 2>/dev/null
        sleep 2
    fi
    
    if ping -c 1 -W 2 $PING_TARGET > /dev/null 2>&1; then
        FAIL_COUNT=0  # Reset fail counter if ping is successful
    else
        remaining_attempts=$((FAIL_THRESHOLD - FAIL_COUNT))
        log_message "Ping failed. Increasing fail count. $remaining_attempts attempts remaining before module restart."
        FAIL_COUNT=$((FAIL_COUNT+1))
    fi
    
    if [ $FAIL_COUNT -ge 2 ]; then
        log_message "Connection lost. Killing existing Quectel processes..."
        kill_quectel_processes
        # Wait for processes to fully terminate
        sleep 2
        # Verify all processes are gone
        still_running=0
        for tool in $QUECTEL_TOOLS; do
            if pidof "$tool" >/dev/null 2>&1; then
                still_running=1
                break
            fi
        done
        if [ $still_running -eq 1 ]; then
            log_message "Some processes still running, waiting..."
            sleep 2
        fi
        log_message "Restarting Quectel connection manager..."
        start_quectel_cm  # Restart the connection
        sleep 3
        # Reconfigure DHCP after restarting quectel-CM
        ifup "$UCI_INTERFACE_NAME" 2>/dev/null
    fi
    
    if [ $FAIL_COUNT -ge 20 ]; then
        log_message "Fail count reached 20. Sending AT+QNWLOCK=\"common/4g\",0 command..."
        sms_tool -D -d $DEVICE at 'AT+QNWLOCK="common/4g",0'  # Unlock cell lock
    fi
    
    if [ $FAIL_COUNT -ge $FAIL_THRESHOLD ]; then
        log_message "Connection lost for too long. Killing all Quectel processes before restarting module..."
        kill_quectel_processes
        sleep 2
        log_message "Restarting module using AT command... Sleeping for 10 seconds..."
        sleep 10
        sms_tool -D -d $DEVICE at "$AT_CMD"  # Send AT command to module
        FAIL_COUNT=0  # Reset fail counter
        sleep 5
        # Reconfigure DHCP after module restart
        configure_dhcp_interface
    fi
    
    sleep $PING_INTERVAL
done