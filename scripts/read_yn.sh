#!/bin/bash
function read_yn() {
    local prompt=$1
    local answer
    while true; do
        read -e -p "$prompt" answer
        case $answer in
            [Yy]* ) echo "y"; break;;
            [Nn]* ) echo "n"; break;;
            * ) echo "Invalid input. Please answer y(es) or n(o).";;
        esac
    done
}