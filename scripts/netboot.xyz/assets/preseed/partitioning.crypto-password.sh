#!/bin/sh

## put some logging in place
echo "Start partitioning.crypto.sh runscript" >> /var/log/syslog

## read crypto_root_passwd env-var from initial kernel parameters
echo "d-i partman-crypto/passphrase password ${crypto_root_passwd}" > /tmp/partitioning.crypto.cfg
echo "d-i partman-crypto/passphrase-again password ${crypto_root_passwd}" >> /tmp/partitioning.crypto.cfg

## add's values to /var/lib/cdebconf/question.dat
debconf-set-selections /tmp/partitioning.crypto.cfg
