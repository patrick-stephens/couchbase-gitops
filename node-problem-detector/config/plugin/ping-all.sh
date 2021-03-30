#!/bin/bash 
# Ping all nodes to confirm they are contactable - is this a failure of our node though?
# TODO: get node ip addresses
for node in "172.18.0.2" "172.18.0.3"; do
    if ! ping -c 3 "$node" &>/dev/null; then
        exit 1
    fi
done
exit 0