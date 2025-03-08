#! /bin/bash

# Variables
declare IN_IFACE="wlan1"
declare OUT_IFACE="eth0"
declare NETWORK="192.168.100.0"
declare NETMASK="255.255.255.0"
declare BROADCAST="192.168.100.255"
declare GATEWAY="192.168.100.1"
declare DHCP_LOW="192.168.100.100"
declare DHCP_HIGH="192.168.100.200"
declare LEASING_TIME="12h"
declare SSID="INTERCEPT_AP"
declare PASSWORD="INTERCEPT_AP_1234"

# Install necessary packages if missing
install_dependencies() {
    for pkg in dnsmasq hostapd; do
        if ! which "$pkg" &> /dev/null; then
            echo "[*] Installing $pkg..."
            if ! apt install -y "$pkg"; then
                echo "[-] Failed to install $pkg. Please check your package manager."
                exit 1
            fi
        fi
    done
}

# Function to check if a network interface exists
validate_network_interface() {
    local iface=$1

    if ! ip link show "$iface" &> /dev/null; then
        echo "[-] Network interface '$iface' not found! Ensure the interface exists and try again."
        exit 1
    fi
}

# Backup the original configuration file
backup_file() {
    local file_path="$1"
    
    if ! [ -f "$file_path" ]; then
        echo "[-] The file '$file_path' does not exist on the system. Aborting."
        exit 1
    fi

    if [ -f "$file_path.bkp" ]; then
        echo "[-] A backup of '$file_path' already exists. Ensure no services are running and clean up before retrying."
        exit 1
    fi

    if ! cp "$file_path" "$file_path.bkp"; then
        echo "[-] Failed to backup '$file_path'. Check permissions or disk space."
        exit 1
    fi
    echo "[+] Backup of '$file_path' created."
}

# Restore the original configuration file
restore_file() {
    local file_path="$1"
    
    if ! [ -f "$file_path.bkp" ]; then
        echo "[-] No backup found for '$file_path'. Cannot restore."
        exit 1
    fi

    if ! mv -f "$file_path.bkp" "$file_path"; then
        echo "[-] Failed to restore '$file_path'. Check permissions or disk space."
        exit 1
    fi

    echo "[+] Restored '$file_path' file"
}

# Start a specific service
start_service() {
    local service="$1"

    if systemctl is-active --quiet "$service"; then
        echo "[*] '$service' service is already running. Attempting to stop it..."
        if ! systemctl stop "$service"; then
            echo "[-] Failed to stop '$service'. Please check the system logs."
            exit 1
        fi
    fi

    if ! systemctl start "$service"; then
        echo "[-] Failed to start '$service' service. Check logs for details."
        stop_services
        exit 1
    fi

    echo "[+] '$service' service started successfully."
}

# Stop a specific service
stop_service() {
    local service="$1"

    if ! systemctl stop "$service"; then
        echo "[-] Failed to stop '$service' service. Check logs for details."
        exit 1
    fi

    echo "[+] Service '$service' stopped."
}

# Configure traffic forwarding
setup_firewall() {
    set -e  # exit immediately if any command fails

    # Enable IP forwarding
    if ! sysctl -w net.ipv4.ip_forward=1 > /dev/null; then
        echo "[-] Failed to enable IP forwarding."
        exit 1
    fi
    echo "net.ipv4.ip_forward=1" | tee /etc/sysctl.d/99-forwarding.conf > /dev/null

    # Apply iptables rules
    if ! iptables -t nat -A POSTROUTING -o "$OUT_IFACE" -j MASQUERADE; then
        echo "[-] Failed to apply NAT rule!"
        exit 1
    fi
    if ! iptables -A FORWARD -i "$IN_IFACE" -o "$OUT_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT; then
        echo "[-] Failed to apply FORWARD rule!"
        exit 1
    fi
    if ! iptables -A FORWARD -i "$OUT_IFACE" -o "$IN_IFACE" -j ACCEPT; then
        echo "[-] Failed to apply FORWARD rule!"
        exit 1
    fi

    # Validate iptables rules
    iptables -t nat -C POSTROUTING -o "$OUT_IFACE" -j MASQUERADE &>/dev/null || { echo "[-] Failed to set NAT rule!"; exit 1; }
    iptables -C FORWARD -i "$IN_IFACE" -o "$OUT_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT &>/dev/null || { echo "[-] Failed to set FORWARD rule!"; exit 1; }
    iptables -C FORWARD -i "$OUT_IFACE" -o "$IN_IFACE" -j ACCEPT &>/dev/null || { echo "[-] Failed to set FORWARD rule!"; exit 1; }

    echo "[+] Firewall rules successfully applied"
}

# Reset traffic forwarding
reset_firewall() {
    # Flush iptables rules
    if ! iptables --flush; then
        echo "[-] Failed to flush iptables rules."
        exit 1
    fi
    if ! iptables --table nat --flush; then
        echo "[-] Failed to flush NAT rules."
        exit 1
    fi
    if ! iptables --delete-chain; then
        echo "[-] Failed to delete iptables chains."
        exit 1
    fi
    if ! iptables --table nat --delete-chain; then
        echo "[-] Failed to delete NAT chains."
        exit 1
    fi
    
    echo "[+] Flushed iptables rules."

    # Disable IP forwarding
    if ! sysctl -w net.ipv4.ip_forward=0 > /dev/null; then
        echo "[-] Failed to disable IP forwarding."
        exit 1
    fi
    rm -f /etc/sysctl.d/99-forwarding.conf || { echo "[-] Failed to remove sysctl config file"; exit 1; }
    
    echo "[+] IP forwarding disabled"
}

# Configure network interface
setup_interface() {
    backup_file /etc/network/interfaces
    
    if ! cat >> /etc/network/interfaces <<EOF
auto $IN_IFACE
iface $IN_IFACE inet static
    address $GATEWAY
    netmask $NETMASK
    network $NETWORK
    broadcast $BROADCAST
EOF
    then
        echo "[-] Failed to update /etc/network/interfaces. Please check permissions and try again."
        exit 1
    fi

    start_service networking
}

# Configure DHCP service
setup_dhcp() {
    backup_file /etc/dnsmasq.conf

    if ! cat > /etc/dnsmasq.conf <<EOF
interface=$IN_IFACE
dhcp-range=$DHCP_LOW,$DHCP_HIGH,$LEASING_TIME
EOF
    then
        echo "[-] Failed to update /etc/dnsmasq.conf. Please check permissions and try again."
        exit 1
    fi
   
    start_service dnsmasq
}

# Configure hostapd service
setup_hostapd() {
    backup_file /etc/hostapd/hostapd.conf    
	
    if ! cat > /etc/hostapd/hostapd.conf <<EOF
interface=$IN_IFACE
driver=nl80211
ssid=$SSID
hw_mode=g
channel=6
wmm_enabled=0
auth_algs=1
wpa=2
wpa_passphrase=$PASSWORD
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
    then
        echo "[-] Failed to update /etc/hostapd/hostapd.conf. Please check permissions and try again."
        exit 1
    fi
    
    start_service hostapd
}

# Cleanup function for restoring system state
cleanup_system() {
    # Restore original configuration files
    restore_file /etc/network/interfaces
    restore_file /etc/dnsmasq.conf
    restore_file /etc/hostapd/hostapd.conf
    
    # Reset firewall rules 
    reset_firewall
    
    echo "[+] Cleanup process completed"
}

# Stop services to reset functionalities
stop_services() {
    # Stop hostapd and dnsmasq services
    stop_service hostapd
    stop_service dnsmasq
    
    # Reset network interface
    ip addr flush dev $IN_IFACE
    systemctl restart networking
    
    echo "[+] Services stopped"
}

# Start services on the machine
start_services() {
    # Validate interfaces
    validate_network_interface $IN_IFACE
    validate_network_interface $OUT_IFACE
    
    # Execute all setup steps
    install_dependencies
    setup_interface
    setup_dhcp
    setup_firewall
    setup_hostapd
    
    echo "[+] Access Point setup complete!"
}


# Hide ^C
stty -echoctl

trap stop_services SIGINT

# Ensure script is run as root
if [ "$EUID" -ne 0 ]
    then echo "[-] Please run as root"
    exit 1
fi

if [[ "$1" == "--start" ]]; then
    start_services
elif [[ "$1" == "--stop" ]]; then
    cleanup_system
    stop_services
elif [[ "$1" == "--cleanup" ]]; then
    cleanup_system
elif [[ "$1" == "--help" ]]; then
    echo "
wifi_ap_setupper.sh

Usage:
    
    --start   Start services
    --stop    Stop services
    --cleanup Clean-up machine

NOTE: Make sure to properly setup the script variables before executing!
    "
else
    echo "Option unrecognized. Use --help to read script helper"
fi

