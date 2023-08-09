#!/bin/bash
function update_install_packages () {
    container_name=$1
    shift
    packages=("$@")

    lxc-attach $container_name -- bash -c "apt-get update -y && apt-get install nano wget software-properties-common ca-certificates curl gnupg git -y"
    sleep 20
    for i in "${packages[@]}"; do
        lxc-attach $container_name -- apt-get install $i -y
    done

}