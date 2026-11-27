#!/bin/sh

## put some logging in place
echo "Start hostname.network.sh runscript" >> /var/log/syslog

{
  echo "export NETDEV=${net_dev_1}"
  echo "export VLAN=${net_vlan_1}"
  echo "export IP=${net_ip_1}"
  echo "export GW=${net_gw_1}"
  echo "export DNS1=${net_ns_1}"
  echo "export DNS2=${net_ns_2}"
  echo "export OLD_GW=${net_gw_old}"
  echo "export NETDEV2=${net_dev_2}"
  echo "export VLAN2=${net_vlan_2}"
  echo "export IP2=${net_ip_2}"
  echo "export IP6=${net_ip6_1}"
  echo "export MASK=${net_mask_1}"
  echo "export BC=${net_bc_1}"
  echo "export GW6=${net_gw6_1}"
  echo "export GW2=${net_gw_2}"
  echo "export MASK2=${net_mask_2}"
  echo "export BC2=${net_bc_2}"
  echo "export DOMAIN=${domain}"
  echo "export BOOTSRV=${http_server}"
  echo "export KERNEL_HOSTNAME=${hostname}"
} > /tmp/net_env.var
