#!/bin/bash
source scripts/validate_ip.sh
function read_ip() {
    local ip
    while true; do
        read -p "Enter the remote server's IP address: " ip
        if validate_ip $ip; then
            echo $ip
            break
        else
            echo "Invalid IP address. Please enter again."
        fi
    done
}