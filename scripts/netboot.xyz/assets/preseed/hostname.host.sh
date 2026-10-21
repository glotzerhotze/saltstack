#!/bin/sh

## put some logging in place
echo "Start hostname.host.sh runscript" >> /var/log/syslog

## read hostname and domain env-vars from initial kernel parameters

# Any hostname and domain names assigned from dhcp take precedence over
# values set here. However, setting the values still prevents the questions
# from being shown, even if values come from dhcp.
echo "d-i netcfg/get_hostname string ${hostname}" > /tmp/hostname.host.cfg

# If you want to force a hostname, regardless of what either the DHCP
# server returns or what the reverse DNS entry for the IP is, uncomment
# and adjust the following line.
echo "d-i netcfg/get_domain string ${domain}" >> /tmp/hostname.host.cfg
