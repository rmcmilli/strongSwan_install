#!/bin/bash
#
# This is a shell script created to install strongSwan and place a configuration file in the correct directory.
# This script is currently built to operate on Ubuntu and CentOS
#
# Function to determine local IP address
get_local_ip() {
    local_ip="$(ip route get 1.1.1.1 | awk -F"src " 'NR==1{split($2,a," ");print a[1]}')"
    #echo "Local IP address is "$local_ip""
}
# Function to build IPsec configuration
build_tunnel_config() {
    sudo touch "$tunnelconfig"
    echo "# Section defining IKE connection configurations.
        connections {
            ipsec {
                local_addrs = "$1"
                remote_addrs = "$2"
                version = "$3"
                mobike = no
                reauth_time = "$4"
                proposals = "$5"
                local {
                    auth = psk
                    id = "$6"
                }
                remote {
                    auth = psk
                    id = "$2"
                }
                children {
                    env {
                        local_ts = "$7"
                        remote_ts = "$8"
                        updown = /usr/lib/ipsec/_updown iptables
                        rekey_time = "$9"
                        esp_proposals = "$p2_props"
                        start_action = trap
                    }
                }
            }
        }
        secrets {
            ike-1 {
                secret = "$psk"
            }
        }
    " | sudo tee -a "$tunnelconfig"
    echo "Tunnel config success. File placed in "$tunnelconfig"."
}
# Function to build baseline configuration
build_base_config() {
    sudo touch "$baseconfig"
    echo "# Include config snippets\r\ninclude conf.d/*.conf" | sudo tee -a "$baseconfig"
    echo "Base config success. File placed in "$baseconfig"."
}
#
# Check if strongSwan is already installed
function strongswan_installed_ubuntu() {
    if apt -qq list "$@" >/dev/null 2>&1; then
        true
    else
        false
    fi
}
#
# Check if strongSwan is already installed on CentOS
function strongswan_installed_centos() {
    if yum list installed "$@" >/dev/null 2>&1; then
        true
    else
        false
    fi
}
#
#
# Define Associative Array
declare -A mymap
# Determine OS version
# Read *release files and place values in associative array
while read line; do
    set -- $(echo $line | tr '=' ' ')
    mymap[$1]=$2
done <<<"$(cat /etc/*release)"
# Uncomment below to print the array
#typeset -p mymap
# Set Linux version with key ID to variable version
version=${mymap[ID]}
#echo "$version"
# Download strongSwan from respective package manager
# Ubuntu
# Disable globbing case-sensitivity
shopt -s nocasematch
# Check version
if [[ "$version" =~ ubuntu ]]; then
    #strongswan_installed_ubuntu strongswan
    sudo apt update &&
        sudo apt install strongswan &&
        sudo apt install strongswan-swanctl &&
        sudo apt install charon-systemd &&
        # Start strongSwan
        sudo systemctl enable strongswan-swanctl.service
    # Set path for tunnel config file
    tunnelconfig=/etc/swanctl/conf.d/tunnel.conf
#CentOS
elif [[ "$version" =~ centos ]]; then
    # Check if strongSwan is already installed
    #strongswan_installed_centos
    sudo yum update &&
        sudo yum -y install epel-release strongswan
    #Set path for tunnel config file
    tunnelconfig=/etc/strongswan/swanctl/conf.d/tunnel.conf
else
    echo "Version Check Failed. This usually means that the OS isn't yet supported by this script."
    exit 1
fi
# Get client variables
read -p "Enter remote endpoint public IP. : " remote_ip
# Enter IKE version number
read -p "Enter IKE version number.  Default is 2 : " ike_version
#Set default IKEv2
ike_version="${ike_version:=2}"
# Enter phase-1 reauth time - Default 28800 seconds
read -p "Enter phase-1 reauthentication time. Default is 28800s. : " p1_reauth
# Set default phase-1 reauth time
p1_reauth="${p1_reauth:=28800s}"
# Enter phase-1 proposals. Default aes256-sha1-ecp384
read -p "Enter phase-1 proposals. Default is aes256-sha1-ecp384. : " p1_props
# Set default phase-1 proposal set
p1_props="${p1_props:=aes256-sha1-ecp384}"
# Have client enter public IP address
read -p "Enter Public IP address. : " public_ip
# Have client enter subnet
read -p "Enter your local tunnel subnet. You may need to create an additional interface or IP address. : " source_subnet
# Enter the remote tunnel subnet.
read -p "Enter the remote tunnel subnet. (ie. 10.10.0.0/16,192.168.0.0/24,172.16.0.1/32) : " destination_subnet
# Enter phase-2 rekey time
read -p "Enter the phase-2 rekey time. Default is 28800s. : " p2_rekey
# Set default phase-2 rekey time
p2_rekey="${p2_rekey:=28800s}"
# Enter phase-2 proposals
read -p "Enter the phase-2 proposals. Default is aes256-sha384. : " p2_props
# Set default phase-2 proposals
p2_props="${p2_props:=aes256-sha384}"
# Have client enter generated pre-shared key and hide input
read -s -p "Enter your pre-shared key. Input will be hidden. : " psk
# Get private IP from localhost
get_local_ip
# Determine if base configuration file swanctl.conf exists in directory with respect to OS version
# Check version
# Ubuntu
if [[ "$version" =~ ubuntu ]]; then
    # Check if default config file exists
    baseconfig=/etc/swanctl/swanctl.conf
    if test -f "$baseconfig"; then
        echo "strongSwan base configuration Exists. Creating tunnel configuration"
        # Check if tunnel configuration already exists. If so, remove and rebuild
        if test -f "$tunnelconfig"; then
            echo "tunnel strongSwan configuration file exists. Removing and rebuilding."
            sudo rm "$tunnelconfig"
            build_tunnel_config "$local_ip" "$remote_ip" "$ike_version" "$p1_reauth" "$p1_props" "$public_ip" "$source_subnet" "$destination_subnet" "$p2_rekey" "$p2_props" "$psk"
        else
            # Set path for tunnel config file
            #tunnelconfig=/etc/swanctl/conf.d/tunnel.conf
            # Create file with client variables
            build_tunnel_config "$local_ip" "$remote_ip" "$ike_version" "$p1_reauth" "$p1_props" "$public_ip" "$source_subnet" "$destination_subnet" "$p2_rekey" "$p2_props" "$psk"
        fi
    else
        echo "strongSwan base configuration does not exist. Creating."
        # Create base config
        build_base_config
        # Set path for tunnel config file
        #tunnelconfig=/etc/swanctl/conf.d/tunnel.conf
        # Create file with client variables
        build_tunnel_config "$local_ip" "$remote_ip" "$ike_version" "$p1_reauth" "$p1_props" "$public_ip" "$source_subnet" "$destination_subnet" "$p2_rekey" "$p2_props" "$psk"
    fi
# CentOS
elif [[ "$version" =~ centos ]]; then
    baseconfig=/etc/strongswan/swanctl/swanctl.conf
    if test -f "$baseconfig"; then
        echo "strongSwan base configuration Exists. Creating tunnel configuration"
        # Check if tunnel configuration already exists. If so, remove and rebuild
        if test -f "$tunnelconfig"; then
            echo "Tunnel strongSwan configuration file exists. Removing and rebuilding."
            sudo rm "$tunnelconfig"
            build_tunnel_config "$local_ip" "$remote_ip" "$ike_version" "$p1_reauth" "$p1_props" "$public_ip" "$source_subnet" "$destination_subnet" "$p2_rekey" "$p2_props" "$psk"
        else
            # Set path for tunnel config file
            #tunnelconfig=/etc/swanctl/conf.d/tunnel.conf
            # Create file with client variables
            build_tunnel_config "$local_ip" "$remote_ip" "$ike_version" "$p1_reauth" "$p1_props" "$public_ip" "$source_subnet" "$destination_subnet" "$p2_rekey" "$p2_props" "$psk"
        fi
    else
        echo "strongSwan base configuration does not exist. Creating."
        # Create base config
        build_base_config
        # Set path for tunnel config file
        #tunnelconfig=/etc/strongswan/swanctl/conf.d/tunnel.conf
        # Create file with client variables
        build_tunnel_config "$local_ip" "$remote_ip" "$ike_version" "$p1_reauth" "$p1_props" "$public_ip" "$source_subnet" "$destination_subnet" "$p2_rekey" "$p2_props" "$psk"
    fi
fi
# Restart strongSwan with respect to OS version
if [[ "$version" =~ ubuntu ]]; then
    sudo swanctl -r
    sudo swanctl -q
    sudo swanctl -i --child env
elif [[ "$version" =~ centos ]]; then
    sudo swanctl -r
    sudo swanctl -q
    sudo swanctl -i --child env
fi
