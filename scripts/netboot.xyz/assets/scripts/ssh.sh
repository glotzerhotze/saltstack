#!/bin/bash

set -e
set -o pipefail

## create .ssh directory for root user
mkdir -p /root/.ssh


## add your public ssh key to access the server
cat << 'EOF' >> /root/.ssh/authorized_keys
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFoWv7STNMUVkQWz0Ns/Ixf2g3RIA5gZw426VAxmr+fr tk@homelab

EOF


## set correct permissions to access the file
chown -R root:root /root/.ssh
chmod 600 /root/.ssh/authorized_keys
chmod 600 /root/.ssh
