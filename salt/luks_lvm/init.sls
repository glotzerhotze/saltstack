# -*- coding: utf-8 -*-
# vim: ft=sls
#
# LVM on LUKS for disks identified by /dev/disk/by-id.
# See pillar.example and README.md.

include:
  - .packages
  - .luks
  - .lvm
  - .filesystems
