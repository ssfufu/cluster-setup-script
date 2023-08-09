#!/bin/bash
function docker_setup () {
    echo ""
    echo ""
    echo "--------------------INSTALLING DOCKER--------------------"
    echo ""
    echo ""

    for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do apt-get remove $pkg; done > /dev/null

    apt-get update -y > /dev/null
    sleep 3
    apt-get install ca-certificates curl gnupg -y > /dev/null

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
        "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
        "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -y > /dev/null
    apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin debootstrap bridge-utils -y > /dev/null

    groupadd docker
    usermod -aG docker devops

    systemctl enable docker.service > /dev/null
    systemctl enable containerd.service > /dev/null

    systemctl restart docker.socket > /dev/null
    systemctl restart docker.service > /dev/null


    echo ""
    echo ""
    echo "--------------------DOCKER INSTALLED--------------------"
}