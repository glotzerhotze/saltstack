#!/bin/sh

## put some logging in place
echo "Start hostname.network.sh runscript" >> /var/log/syslog

echo "export NETDEV=${net_dev_1}" > /tmp/net_env.var
echo "export VLAN=${net_vlan_1}" >> /tmp/net_env.var
echo "export IP=${net_ip_1}" >> /tmp/net_env.var
echo "export GW=${net_gw_1}" >> /tmp/net_env.var
echo "export DNS1=${net_ns_1}" >> /tmp/net_env.var
echo "export DNS2=${net_ns_2}" >> /tmp/net_env.var
echo "export OLD_GW=${net_gw_old}" >> /tmp/net_env.var
echo "export NETDEV2=${net_dev_2}" >> /tmp/net_env.var
echo "export VLAN2=${net_vlan_2}" >> /tmp/net_env.var
echo "export IP2=${net_ip_2}" >> /tmp/net_env.var
echo "export IP6=${net_ip6_1}" >> /tmp/net_env.var
echo "export MASK=${net_mask_1}" >> /tmp/net_env.var
echo "export BC=${net_bc_1}" >> /tmp/net_env.var
echo "export GW6=${net_gw6_1}" >> /tmp/net_env.var
echo "export GW2=${net_gw_2}" >> /tmp/net_env.var
echo "export MASK2=${net_mask_2}" >> /tmp/net_env.var
echo "export BC2=${net_bc_2}" >> /tmp/net_env.var
echo "export DOMAIN=${domain}" >> /tmp/net_env.var
echo "export BOOTSRV=${http_server}" >> /tmp/net_env.var
echo "export KERNEL_HOSTNAME=${node_hostname}" >> /tmp/net_env.var