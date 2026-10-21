#!/usr/bin/env bash

rsync -av --recursive --delete -e "ssh -l root" --exclude 'deploy.sh' /Users/tk/code/saltstack/scripts/netboot.xyz/assets/* \
 192.168.23.65:/var/lib/containers/storage/volumes/netbootxyz-assets/_data/

scp /Users/tk/code/saltstack/3pfs/salt-bootstrap/bootstrap-salt.sh \
 root@192.168.23.65:/var/lib/containers/storage/volumes/netbootxyz-assets/_data/scripts/bootstrap-salt.sh