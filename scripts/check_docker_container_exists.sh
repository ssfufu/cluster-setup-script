#!/bin/bash
function check_docker_container_exists() {
    local dcname="$1"
    if [ "$(docker ps -a -q -f name=^/${dcname}$)" ]; then
        return 0
    else
        return 1
    fi
}
