#!/bin/bash

set -e
set -o pipefail

##
### source environment first
##
source /root/net_env.var

##
### setup dropbear-ssh-root-decrypt config
##
## provide vconfig to allow configuration of VLAN interface in busybox
cat << 'EOF' > /etc/initramfs-tools/scripts/init-bottom/vconfig
#!/bin/sh

PREREQ="8021q"

prereqs()
{
  echo "$PREREQ"
}

case $1 in
# get pre-requisites
prereqs)
  prereqs
  exit 0
  ;;
esac

NIC=${DEVICE%.*}
VLAN=${DEVICE#*.}

ifconfig ${NIC}.${VLAN} down
vconfig rem  ${NIC}.${VLAN}

exit 0

EOF


## hook into initramfs to utilize vconfig for VLAN configuration
cat << 'EOF' > /etc/initramfs-tools/hooks/vconfig
#!/bin/sh

PREREQ=""

prereqs()
{
  echo "$PREREQ"
}

case $1 in
prereqs)
  prereqs
  exit 0
  ;;
esac

if [ ! -x /sbin/vconfig ]; then
  exit 0
fi

. /usr/share/initramfs-tools/hook-functions

copy_exec /sbin/vconfig

manual_add_modules 8021q

EOF

## configuration of the VLAN interface before mounting init
cat << 'EOF' > /etc/initramfs-tools/scripts/init-premount/vconfig
#!/bin/sh

PREREQ="udev"

prereqs()
{
  echo "$PREREQ"
}

case $1 in
# get pre-requisites
prereqs)
  prereqs
  exit 0
  ;;
esac

. /scripts/functions
. /conf/initramfs.conf

if [[ "${VLAN}" == "y" ]]; then
  NIC=${DEVICE%.*}
  VLAN=${DEVICE#*.}
  ifconfig ${NIC} up
  vconfig add ${NIC} ${VLAN}
  configure_networking &
fi

exit 0

EOF

cat << EOF >> /etc/initramfs-tools/initramfs.conf
DEVICE=${NETDEV}
DROPBEAR=y
IP=${IP}"::${GW}:255.255.255.0:${KERNEL_HOSTNAME}.${DOMAIN}:${NETDEV}:off"
VLAN=n

EOF

## make the scripts executable so update-initramfs will pick them up
chmod 755 /etc/initramfs-tools/scripts/init-premount/vconfig
chmod 755 /etc/initramfs-tools/hooks/vconfig
chmod 755 /etc/initramfs-tools/scripts/init-bottom/vconfig


## set some dropbear options - aka. no remote / local ssh-forwarding - timeout 60 sec
echo 'DROPBEAR_OPTIONS="-j -k -I 60"' >> /etc/dropbear/initramfs/config
echo 'IFDOWN="*"' >> /etc/dropbear/initramfs/config

## create some rsa-keypair (needed?!?)
#cd /etc/dropbear/initramfs
#/usr/lib/dropbear/dropbearconvert dropbear openssh dropbear_rsa_host_key id_rsa
#dropbearkey -y -f dropbear_rsa_host_key |grep "^ssh-rsa " > id_rsa.pub
#cd

## convert existing host-keys to dropbear
dropbearconvert openssh dropbear /etc/ssh/ssh_host_rsa_key /etc/dropbear/initramfs/dropbear_rsa_host_key

## rsa based authentication is advised over ecdsa and dss
cat << 'EOF' > /etc/dropbear/initramfs/authorized_keys
no-port-forwarding,no-agent-forwarding,no-X11-forwarding,command="/bin/cryptroot-unlock" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFoWv7STNMUVkQWz0Ns/Ixf2g3RIA5gZw426VAxmr+fr tk@homelab

EOF

## change GRUB2 settings so the kernel knows about the IP address and network to use for the interface
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet"/#GRUB_CMDLINE_LINUX_DEFAULT="quiet"/g' /etc/default/grub
echo "GRUB_CMDLINE_LINUX_DEFAULT=\"ip=${IP}::${GW}:255.255.255.0:${KERNEL_HOSTNAME}.${DOMAIN}:${NETDEV}\"" >> /etc/default/grub

## update all dependencies
update-grub2
update-initramfs -u