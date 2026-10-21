#!/bin/bash

set -e
set -o pipefail

##
### source environment first
##
source /root/net_env.var

## install NetworkManager and purge netinst setup
DEBIAN_FRONTEND=noninteractive apt-get install -y network-manager;
DEBIAN_FRONTEND=noninteractive apt-get purge -y ifupdown dhcpcd-base;

## enable the service so it will be active on next reboot
systemctl enable NetworkManager;

## create a NetworkManager connection for the machine for static IPAM
cat << EOF > /etc/NetworkManager/system-connections/schnorchel-mgmt.nmconnection
## Managed by Salt (nm_connections formula). Local changes will be overwritten.

[connection]
id=schnorchel-mgmt
interface-name=${NETDEV}
type=ethernet
uuid=97ea5a2e-7a51-312f-838e-bf402f666166

[ipv4]
address1=${IP}/24
dns=${DNS1};${DNS2};
dns-search=${DOMAIN};
gateway=${GW}
ignore-auto-dns=true
may-fail=false
method=manual

[ipv6]
addr-gen-mode=default
method=auto
EOF

cat << EOF > /etc/NetworkManager/NetworkManager.conf
[main]
configure-and-quit=no
no-auto-default=*
plugins=keyfile

[ifupdown]
managed=false

EOF

chmod 600 /etc/NetworkManager/system-connections/schnorchel-mgmt.nmconnection
rm -rf /etc/network/interfaces
rm -rf /etc/NetworkManager/system-connections/'Wired connection 1'
nmcli connection reload
nmcli connection modify "Wired connection 1" connection.autoconnect no
nmcli connection down "Wired connection 1"
nmcli connection delete "Wired connection 1"
nmcli connection up schnorchel-mgmt
