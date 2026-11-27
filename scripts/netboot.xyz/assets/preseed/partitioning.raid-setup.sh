#!/bin/sh

## put some logging in place
echo "Start partitioning.raid-setup.sh runscript" >> /var/log/syslog

## check if the machine needs a software-raid setup - otherwise asume hardware-raid
## and if ${soft_raid} == "true" --> setup the first two disks as a software-raid
## with /dev/md0 as uncrypted /boot device
## and /dev/md1 as the crypted blockdevice for the usual lvm setup
if [ "${soft_raid}" = "true" ]; then
  echo "d-i partman-auto/disk string /dev/md1" > /tmp/partitioning.raid.cfg;
  printf '%s\n' 'o' 'n' 'p' '1' ' ' '+512M' 'Y' 't' 'fd' 'w' > /tmp/fdisk1
  printf '%s\n' 'n' 'p' '2' ' ' ' ' 't' '2' 'fd' 'w' > /tmp/fdisk2
  cat /tmp/fdisk1 | fdisk /dev/sda
  cat /tmp/fdisk1 | fdisk /dev/sdb
  cat /tmp/fdisk2 | fdisk /dev/sda
  cat /tmp/fdisk2 | fdisk /dev/sdb
  echo "y" | mdadm --create --force --metadata=1.2 --level=1 --raid-devices=2 /dev/md0 /dev/sda1 /dev/sdb1
  echo "y" | mdadm --create --force --metadata=1.2 --level=1 --raid-devices=2 /dev/md1 /dev/sda2 /dev/sdb2
  sleep 20
else
  if [ "${hostname}" = mt23 ] || [ "${hostname}" = mt24 ] || [ "${hostname}" = mt25 ]; then
    echo "d-i partman-auto/disk string /dev/nvme0n1" > /tmp/partitioning.raid.cfg
  else
    echo "d-i partman-auto/disk string /dev/sda" > /tmp/partitioning.raid.cfg
  fi;
fi;

## add's values to /var/lib/cdebconf/question.dat
debconf-set-selections /tmp/partitioning.raid.cfg
