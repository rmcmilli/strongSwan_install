#!/bin/bash
#
# This is a shell script created to install strongSwan and place a configuration file in the correct directory.
# This script is currently built to run on Ubuntu and CentOS.
# Default behavior is to authenticate via PSK.
#
#
#
main() {
    # Retrieve OS version
    determine_os_version
    # Determine shell parameters
    determine_shell_parameters
    # Install dependencies
    install_dependencies
    # Determine Public IP address
    get_public_ip
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
determine_shell_parameters() {
    bold=$(tput bold)
    normal=$(tput sgr0)
}
install_dependencies() {
    if [[ "$version" =~ "ubuntu" ]]; then
        strongswan_install_ubuntu
    elif [[ "$version" =~ "centos" ]]; then
        strongswan_install_centos
    fi
}
# Function to determine Public IP address
get_public_ip() {
    generated_public_ip="$(dig +short myip.opendns.com @resolver1.opendns.com)"
    #echo "$generated_public_ip"
}
# Function to determine local IP address
get_local_ip() {
    # local_ip="$(ip route get $remote_ip | awk -F"src " 'NR==1{split($2,a," ");print a[1]}')"
    local_ip="$(awk -F"src " 'NR==1{split($2,a," ");print a[1]}' <<<"ip route get $remote_ip")"
    local_int="$(ip route get $remote_ip | awk -F"dev " 'NR==1{split($2,a," ");print a[1]}')"
    #echo "Local IP address is "$local_ip""
}
calculate_first_subnet_ip() {
    subnet="$(cut -d '/' -f1 <<<"$1")"
    mask="$(cut -d '/' -f2 <<<"$1")"
    A="$(cut -d '.' -f1 <<<"$subnet")"
    B="$(cut -d '.' -f2 <<<"$subnet")"
    C="$(cut -d '.' -f3 <<<"$subnet")"
    D="$(cut -d '.' -f4 <<<"$subnet")"
    (( E=D+1 ))
    first_subnet_ip="$A.$B.$C.$E/$mask"
}
configure_secondary_ip() {
    if [ "$1" == "yes" ]; then
        calculate_first_subnet_ip "$2"
        echo "${bold}Creating secondary IP $first_subnet_ip on dev $local_int${normal}"
        sudo ip addr add "$first_subnet_ip" brd + dev "$local_int"
    else
        echo "${bold}Not creating secondary IP address. If a local connection to source subnet does not already exist, routing may fail and 'ip route list table 220' WILL fail. ${normal}"
    fi
}
# Function to build IPsec configuration
build_tunnel_config() {
    sudo touch "$tunnelconfig"
    echo "# Section defining IKE connection configurations.
        connections {
            ipsec {
                local_addrs = $1
                remote_addrs = $2
                version = $3
                mobike = no
                reauth_time = $4
                proposals = $5
                local {
                    auth = psk
                    id = $6
                }
                remote {
                    auth = psk
                    id = $2
                }
                children {
                    env {
                        local_ts = $7
                        remote_ts = $8
                        updown = /usr/lib/ipsec/_updown iptables
                        rekey_time = $9
                        esp_proposals = ${10}
                        start_action = trap
                    }
                }
            }
        }
        secrets {
            ike-1 {
                secret = ${11}
            }
        }
    " | sudo tee -a "$tunnelconfig"
    sleep 3
    validate_tunnel_config
}
validate_tunnel_config() {
    if sudo test -f "$tunnelconfig"; then
        read -erp "${bold} *Please confirm the configuration above. If correct, press Enter. If incorrect enter \"no\" : ${normal} " confirm_tunnel_config_boolean
        confirm_tunnel_config_boolean="${confirm_tunnel_config_boolean:=yes}"
        if [[ "$confirm_tunnel_config_boolean" == "yes" ]]; then
            echo "${bold}Tunnel config success. File placed in $tunnelconfig${normal}."
            return
        elif [[ "$confirm_tunnel_config_boolean" == "no" ]]; then
            get_client_variables
            check_and_install
        else
            # echo "${bold}You have input an invalid option.${normal}"
            validate_tunnel_config
        fi
    else
        echo "${bold}Creation of tunnel configuration failed.${normal}"
        exit 1
    fi
}
# Function to build baseline configuration
build_base_config() {
    sudo touch "$baseconfig"
    printf "# Include config snippets\r\ninclude conf.d/*.conf" | sudo tee -a "$baseconfig"
    if sudo test -f "$baseconfig"; then
        echo "${bold}Base configuration success. File placed in $baseconfig.${normal}"
    else
        echo "${bold}Base configuration creation failed.${normal}"
        exit 1
    fi
}
#
# Check if strongSwan is already installed
strongswan_installed_ubuntu() {
    if apt -qq list "$@" >/dev/null 2>&1; then
        true
    else
        false
    fi
}
#
# Check if strongSwan is already installed on CentOS
strongswan_installed_centos() {
    if yum list installed "$@" >/dev/null 2>&1; then
        true
    else
        false
    fi
}
#
# Determine OS Version
determine_os_version() {
    # Define Associative Array
    declare -A mymap
    # Read files ending in 'release' in /etc/ and place OS details in associative array
    while read -r line; do
        if [ "$line" = " " ] || [ "$line" = "" ]; then
            continue
        else
            #set -- "$(echo "$line" | tr '=' ' ')"
            param="$(cut -d '=' -f1 <<<"$line")"
            value="$(cut -d '=' -f2 <<<"$line")"
            mymap["$param"]="$value"
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
strongswan_install_ubuntu() {
    sudo apt update
    sudo apt -y install strongswan
    sudo apt -y install strongswan-swanctl
    sudo apt -y install charon-systemd
    # Start strongSwan
    sudo systemctl enable strongswan-swanctl.service
    # Set path for tunnel config file
    tunnelconfig=/etc/swanctl/conf.d/tunnel.conf
}
# CentOS
strongswan_install_centos() {
    sudo yum update
    sudo yum install -y epel-release
    sudo yum install -y strongswan
    sudo yum install -y bind-utils
    # Set path for tunnel config file
    tunnelconfig=/etc/strongswan/swanctl/conf.d/tunnel.conf
}
# Check version and install strongSwan
# Ubuntu
check_and_install() {
    if [[ "$version" =~ "ubuntu" ]]; then
        #strongswan_install_ubuntu
        # Check if default config file exists
        baseconfig=/etc/swanctl/swanctl.conf
        if sudo test -f "$baseconfig"; then
            echo "${bold}strongSwan base configuration exists. Creating tunnel configuration${normal}"
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
    # CentOS
    elif [[ "$version" =~ "centos" ]]; then
        #strongswan_install_centos
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
        echo "${bold}Version check failed. This usually means that the OS isn't yet supported by this script. ${normal}"
        exit 1
    fi
}
restart_strongswan() {
    # Restart strongSwan with respect to OS version
    if [[ "$version" =~ "ubuntu" ]]; then
        echo "${bold}Restarting strongSwan and attempting to connect to remote endpoint.${normal} "
        sudo swanctl -r
        sudo swanctl -q
        sudo swanctl -i --child env
    elif [[ "$version" =~ "centos" ]]; then
        echo "${bold}Restarting strongSwan and attempting to connect to remote endpoint.${normal} "
        sudo service strongswan restart
        sleep 3s
        sudo swanctl -r
        sudo swanctl -q
        sudo swanctl -i --child env
    fi
}
# Get client variables
get_client_variables() {
    read -erp "${bold} *Enter remote endpoint public IP. : " remote_ip
    # Set default remote public IP
    # remote_ip="${remote_ip:=}"
    # Have client enter public IP address
    read -erp "${bold} *Is your public IP address $generated_public_ip? If yes, press enter. If no, please enter your public IP. : " public_ip
    # Set default public IP to generated value
    public_ip="${public_ip:=$generated_public_ip}"
    # Enter IKE version number
    read -erp "${bold} *Enter IKE version number.  Default is 2 : " ike_version
    #Set default IKEv2
    ike_version="${ike_version:=2}"
    # Enter phase-1 proposals. Default aes256-sha1-ecp384. For more details please see https://wiki.strongswan.org/projects/strongswan/wiki/IKEv2CipherSuites
    read -erp " *Enter phase-1 proposals. Default is aes256-sha1-ecp384. For more details please see https://wiki.strongswan.org/projects/strongswan/wiki/IKEv2CipherSuites : " p1_props
    # Set default phase-1 proposal set
    p1_props="${p1_props:=aes256-sha1-ecp384}"
    # Enter phase-1 reauth time - Default 28800 seconds
    read -erp "${bold} *Enter phase-1 key lifetime. Default is 28800s. : " p1_reauth
    # Set default phase-1 key lifetime
    p1_reauth="${p1_reauth:=28800s}"
    # Enter phase-2 proposals
    read -erp "${bold} *Enter the phase-2 proposals. Default is aes256-sha384. For more details please see https://wiki.strongswan.org/projects/strongswan/wiki/IKEv2CipherSuites : " p2_props
    # Set default phase-2 proposals
    p2_props="${p2_props:=aes256-sha384}"
    # Enter phase-2 rekey time
    read -erp "${bold} *Enter the phase-2 rekey time. Default is 28800s. : " p2_rekey
    # Set default phase-2 rekey time
    p2_rekey="${p2_rekey:=28800s}"
    # Enter the remote tunnel subnet.
    read -erp "${bold} *Enter the remote tunnel subnet in CIDR notation. If you would like to use multiple subnets, please seperate with a comma. (ie. 10.10.0.0/16,192.168.0.0/24) : " destination_subnet
    # Have client enter subnet
    read -erp "${bold} *Enter your local tunnel subnet in CIDR notation. (ie. 192.168.0.0/24) You may need to configure an additional interface or IP address. : " source_subnet
    # Determine whether or not to create secondary IP address on outbound interface
    read -erp "${bold} *Would you like to configure a secondary IP address from your source subnet? If there is not currently a local connection to the source subnet, please enter 'yes'. Please use 'yes' or 'no'. : " secondary_ip_boolean
    # Have client enter generated pre-shared key
    read -erp "${bold} *Enter your pre-shared key. : " psk
}
main