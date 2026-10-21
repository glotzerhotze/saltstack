#!/bin/bash
#
# Runs inside the target chroot from preseed/late_command, e.g.:
#   d-i preseed/late_command string cp /net_env.var /late-network.sh /target/root/; \
#       in-target /bin/bash /root/late-network.sh
#
# NetworkManager is NOT running inside the chroot, so this script only writes
# files. No nmcli calls here; NetworkManager picks everything up on first boot.

set -e
set -o pipefail

##
### source environment first and make sure nothing is empty
##
source /root/net_env.var
: "${NETDEV:?}" "${IP:?}" "${GW:?}" "${DNS1:?}" "${DNS2:?}" "${DOMAIN:?}"

## install NetworkManager and purge netinst setup
export DEBIAN_FRONTEND=noninteractive
apt-get install -y network-manager
apt-get purge -y ifupdown dhcpcd-base

## enable the service so it will be active on next reboot (works offline in a chroot)
systemctl enable NetworkManager.service

install -d -m 755 /etc/NetworkManager/conf.d /etc/NetworkManager/system-connections

## override settings in conf.d instead of replacing the packaged conffile
cat << 'EOF' > /etc/NetworkManager/conf.d/90-local.conf
[main]
plugins=keyfile
no-auto-default=*
EOF

## static profile for the management interface
CONN=/etc/NetworkManager/system-connections/schnorchel-mgmt.nmconnection
cat << EOF > "$CONN"
## Managed by Salt (nm_connections formula). Local changes will be overwritten.

[connection]
id=schnorchel-mgmt
uuid=97ea5a2e-7a51-312f-838e-bf402f666166
type=ethernet
interface-name=${NETDEV}
autoconnect=true
autoconnect-priority=100

[ipv4]
method=manual
address1=${IP}/24
gateway=${GW}
dns=${DNS1};${DNS2};
dns-search=${DOMAIN};
ignore-auto-dns=true
may-fail=false

[ipv6]
method=auto
addr-gen-mode=default
EOF

chown root:root /etc/NetworkManager/system-connections/schnorchel-mgmt.nmconnection
chmod 600 /etc/NetworkManager/system-connections/schnorchel-mgmt.nmconnection

## leftovers from the installer's ifupdown setup
rm -f /etc/network/interfaces
