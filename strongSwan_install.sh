#!/bin/bash
#
# This is a shell script created to install strongSwan and place a configuration file in the correct directory.
# This script is currently built to run on Ubuntu and CentOS.
# Default behavior is to authenticate via PSK
# Next goal is to have an un-interactive mode with flags
#
#
#
function main() {
    # Retrieve OS version
    determine_OS_version
    # Determine shell parameters
    determine_shell_parameters
    # Determine tunnel parameters
    get_client_variables
    # Determine local IP address
    get_local_ip
    # Configure secondary IP address if needed
    configure_secondary_ip "$secondary_ip_boolean" "$source_subnet"
    # Confirm OS version is correct then install and configure
    check_and_install
    # Restart strongSwan and initiate connection
    restart_strongswan
}
function determine_shell_parameters() {
    bold=$(tput bold)
    normal=$(tput sgr0)
}
# Function to determine local IP address
function get_local_ip() {
    local_ip="$(ip route get $remote_ip | awk -F"src " 'NR==1{split($2,a," ");print a[1]}')"
    local_int="$(ip route get $remote_ip | awk -F"dev " 'NR==1{split($2,a," ");print a[1]}')"
    #echo "Local IP address is "$local_ip""
}
function calculate_first_subnet_ip() {
    subnet="$(cut -d '/' -f1 <<<"$1")"
    mask="$(cut -d '/' -f2 <<<"$1")"
    A="$(cut -d '.' -f1 <<<"$subnet")"
    B="$(cut -d '.' -f2 <<<"$subnet")"
    C="$(cut -d '.' -f3 <<<"$subnet")"
    D="$(cut -d '.' -f4 <<<"$subnet")"
    let E=$D+1
    first_subnet_ip=""$A"."$B"."$C"."$E"/"$mask""
}
function configure_secondary_ip() {
    if [ "$1" == "yes" ]; then
        calculate_first_subnet_ip "$2"
        echo "${bold}Creating secondary IP "$first_subnet_ip" on dev "$local_int"${normal}"
        sudo ip addr add "$first_subnet_ip" brd + dev "$local_int"
    elif [ "$1" == "no" ]; then
        echo "${bold}Not creating secondary IP address. If connection to source subnet does not already exist, routing may fail and 'ip route list table 220' WILL fail. ${normal}"
    else 
        echo "Please enter 'yes' or 'no'."
        configure_secondary_ip "$1" "$2"
    fi
}
# Function to build IPsec configuration
function build_tunnel_config() {
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
                        esp_proposals = "${10}"
                        start_action = trap
                    }
                }
            }
        }
        secrets {
            ike-1 {
                secret = "${11}"
            }
        }
    " | sudo tee -a "$tunnelconfig"
    echo "${bold}Tunnel config success. File placed in "$tunnelconfig"${normal}."
}
# Function to build baseline configuration
function build_base_config() {
    sudo touch "$baseconfig"
    echo "# Include config snippets\r\ninclude conf.d/*.conf" | sudo tee -a "$baseconfig"
    if test -f "$baseconfig"; then
        echo "${bold}Base configuration success. File placed in "$baseconfig".${normal}"
    else
        echo "${bold}Base configuration creation failed. Please contact a Seed CX network engineer.${normal}"
        exit 1
    fi
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
# Determine OS Version
# Define Associative Array
function determine_OS_version() {
    declare -A mymap
    # Read *release files and place values in associative array
    while read line; do
        if [ "$line" = " " ] || [ "$line" = "" ]; then
            continue
        else
            set -- $(echo $line | tr '=' ' ')
            mymap["$1"]=$2
        fi
    done <<<"$(cat /etc/*release)"
    # Uncomment below to print the array
    #typeset -p mymap
    # Set Linux version with key ID to variable version
    version=${mymap[ID]}
    #echo "$version"
    # Disable globbing case-sensitivity
    shopt -s nocasematch
}
# Install strongSwan
# Ubuntu
function strongswan_install_ubuntu() {
    sudo apt update &&
        sudo apt -y install strongswan &&
        sudo apt -y install strongswan-swanctl &&
        sudo apt -y install charon-systemd &&
        # Start strongSwan
        sudo systemctl enable strongswan-swanctl.service
    # Set path for tunnel config file
    tunnelconfig=/etc/swanctl/conf.d/tunnel.conf
}
# CentOS
function strongswan_install_centos() {
    sudo yum update &&
        sudo yum -y install epel-release &&
        sudo yum -y install strongswan
    #Set path for tunnel config file
    tunnelconfig=/etc/strongswan/swanctl/conf.d/tunnel.conf
}
# Check version and install strongSwan
# Ubuntu
function check_and_install() {
    if [[ "$version" =~ "ubuntu" ]]; then
        strongswan_install_ubuntu
        # Check if default config file exists
        baseconfig=/etc/swanctl/swanctl.conf
        if test -f "$baseconfig"; then
            echo "${bold}strongSwan base configuration exists. Creating tunnel configuration${normal}"
            # Check if tunnel configuration already exists. If so, remove and rebuild
            if test -f "$tunnelconfig"; then
                echo "${bold}strongSwan tunnel configuration file exists. Removing and rebuilding.${normal}"
                sudo rm "$tunnelconfig"
                build_tunnel_config "$local_ip" "$remote_ip" "$ike_version" "$p1_reauth" "$p1_props" "$public_ip" "$source_subnet" "$destination_subnet" "$p2_rekey" "$p2_props" "$psk"
            else
                # Create file with client variables
                build_tunnel_config "$local_ip" "$remote_ip" "$ike_version" "$p1_reauth" "$p1_props" "$public_ip" "$source_subnet" "$destination_subnet" "$p2_rekey" "$p2_props" "$psk"
            fi
        else
            echo "${bold}strongSwan base configuration does not exist. Creating.${normal}"
            # Create base config
            build_base_config
            # Create file with client variables
            build_tunnel_config "$local_ip" "$remote_ip" "$ike_version" "$p1_reauth" "$p1_props" "$public_ip" "$source_subnet" "$destination_subnet" "$p2_rekey" "$p2_props" "$psk"
        fi
    #CentOS
    elif [[ "$version" =~ "centos" ]]; then
        strongswan_install_centos
        baseconfig=/etc/strongswan/swanctl/swanctl.conf
        sleep 3s
        if sudo test -f "$baseconfig"; then
            echo "${bold}strongSwan base configuration Exists. Creating tunnel configuration.${normal}"
            # Check if tunnel configuration already exists. If so, remove and rebuild
            if sudo test -f "$tunnelconfig"; then
                echo "${bold}strongSwan tunnel configuration file exists. Removing and rebuilding.${normal}"
                sudo rm "$tunnelconfig"
                build_tunnel_config "$local_ip" "$remote_ip" "$ike_version" "$p1_reauth" "$p1_props" "$public_ip" "$source_subnet" "$destination_subnet" "$p2_rekey" "$p2_props" "$psk"
            else
                # Create file with client variables
                build_tunnel_config "$local_ip" "$remote_ip" "$ike_version" "$p1_reauth" "$p1_props" "$public_ip" "$source_subnet" "$destination_subnet" "$p2_rekey" "$p2_props" "$psk"
            fi
        else
            echo "${bold}strongSwan base configuration does not exist. Creating.${normal}"
            # Create base config
            build_base_config
            # Create file with client variables
            build_tunnel_config "$local_ip" "$remote_ip" "$ike_version" "$p1_reauth" "$p1_props" "$public_ip" "$source_subnet" "$destination_subnet" "$p2_rekey" "$p2_props" "$psk"
        fi
    else
        echo "${bold}Version check failed. This usually means that the OS isn't yet supported by this script. Please contact a Seed CX network engineer for assistance. ${normal}"
        exit 1
    fi
}
function restart_strongswan() {
    # Restart strongSwan with respect to OS version
    if [[ "$version" =~ "ubuntu" ]]; then
        sudo swanctl -r
        sudo swanctl -q
        sudo swanctl -i --child env
    elif [[ "$version" =~ "centos" ]]; then
        sudo service strongswan restart
        sleep 3s
        sudo swanctl -r &&
            sudo swanctl -q &&
            sudo swanctl -i --child env
    fi
}
function get_client_variables() {
    # Get client variables
    read -p "Enter remote endpoint public IP. : " remote_ip
    # Have client enter public IP address
    read -p "Enter local public IP address. : " public_ip
    # Enter IKE version number
    read -p "Enter IKE version number.  Default is 2 : " ike_version
    #Set default IKEv2
    ike_version="${ike_version:=2}"
    # Enter phase-1 proposals. Default aes256-sha1-ecp384. For more details please see https://wiki.strongswan.org/projects/strongswan/wiki/IKEv2CipherSuites
    read -p "Enter phase-1 proposals. Default is aes256-sha1-ecp384. For more details please see https://wiki.strongswan.org/projects/strongswan/wiki/IKEv2CipherSuites : " p1_props
    # Set default phase-1 proposal set
    p1_props="${p1_props:=aes256-sha1-ecp384}"
    # Enter phase-1 reauth time - Default 28800 seconds
    read -p "Enter phase-1 key lifetime. Default is 28800s. : " p1_reauth
    # Set default phase-1 key lifetime
    p1_reauth="${p1_reauth:=28800s}"
    # Enter phase-2 proposals
    read -p "Enter the phase-2 proposals. Default is aes256-sha384. For more details please see https://wiki.strongswan.org/projects/strongswan/wiki/IKEv2CipherSuites : " p2_props
    # Set default phase-2 proposals
    p2_props="${p2_props:=aes256-sha384}"
    # Enter phase-2 rekey time
    read -p "Enter the phase-2 rekey time. Default is 28800s. : " p2_rekey
    # Set default phase-2 rekey time
    p2_rekey="${p2_rekey:=28800s}"
    # Enter the remote tunnel subnet.
    read -p "Enter the remote tunnel subnet. (ie. 10.10.0.0/16,192.168.0.0/24,172.16.0.1/32) : " destination_subnet
    # Have client enter subnet
    read -p "Enter your local tunnel subnet. You may need to create an additional interface or IP address. : " source_subnet
    # Determine whether or not to create secondary IP address on outbound interface
    read -p "Would you like to configure a secondary IP address from your source subnet? If there is not currently a local connection to the source subnet, enter 'yes'. Please use 'yes' or 'no'. : " secondary_ip_boolean
    # Have client enter generated pre-shared key
    read -p "Enter your pre-shared key. : " psk
}
main
