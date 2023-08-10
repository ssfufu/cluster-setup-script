#!/bin/bash

cadvisor_latest_version=$(curl -s "https://gcr.io/v2/cadvisor/cadvisor/tags/list" | jq -r '.tags[]' | sort -V | tail -n 1)
cadvisor_version_full="gcr.io/cadvisor/cadvisor:${cadvisor_latest_version}"
sed -i "s|image:.*|image: ${cadvisor_version_full}|" /root/cluster-setup-script/docker_compose_files/cadvisor/docker-compose.yml