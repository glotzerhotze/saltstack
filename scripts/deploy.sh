#!/usr/bin/env bash

rsync -av --recursive --delete -e "ssh -l root" --exclude 'salt-bootstrap' /Users/tk/code/saltstack/3pfs/* \
 192.168.23.65:/var/lib/containers/storage/volumes/salt-master-3pfs/_data/

rsync -av --recursive --delete -e "ssh -l root" /Users/tk/code/saltstack/modules \
 192.168.23.65:/var/lib/containers/storage/volumes/salt-master-srv/_data/

rsync -av --recursive --delete -e "ssh -l root" /Users/tk/code/saltstack/pillar \
 192.168.23.65:/var/lib/containers/storage/volumes/salt-master-srv/_data/

rsync -av --recursive --delete -e "ssh -l root" /Users/tk/code/saltstack/reactor \
 192.168.23.65:/var/lib/containers/storage/volumes/salt-master-srv/_data/

rsync -av --recursive --delete -e "ssh -l root" /Users/tk/code/saltstack/salt \
 192.168.23.65:/var/lib/containers/storage/volumes/salt-master-srv/_data/

rsync -av --recursive --delete -e "ssh -l root" /Users/tk/code/saltstack/config/* \
 192.168.23.65:/var/lib/containers/storage/volumes/salt-master-config/_data/

ssh root@192.168.23.65 'systemctl restart salt-master-pod'
