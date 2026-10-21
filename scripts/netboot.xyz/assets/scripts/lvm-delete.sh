#!/bin/bash

set -e
set -o pipefail

##
### setup env_vars - we need KUBE_ROLE here
##
source /etc/net_env.var

## delete the obsolete logical volume deleteme mounted at /data (because no free disk-space via debian-installer)
umount /dev/mapper/vg0-deleteme
lvremove -y --quiet --noudevsync /dev/vg0/deleteme
sed -i '/\/dev\/mapper\/vg0-deleteme/d' /etc/fstab
