#!/bin/bash
function read_non_empty() {
    local prompt=$1
    local is_password=$2
    local answer
    while true; do
        if [[ "$is_password" = "true" ]]; then
            read -s -p "$prompt" answer
        else
            read -p "$prompt" answer
        fi
        if [[ -z "$answer" ]]; then
            echo "Please enter a value."
        else
            echo $answer
            break
        fi
    done
}