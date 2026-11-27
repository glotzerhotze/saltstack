########################################################################
# Example pillar data for the write_environment formula.
#
# Each key under write_environment is an arbitrary identifier - it is
# only used to name the generated Salt states and to build the
# contents_pillar lookup path (write_environment:<name>:config).
#
# Supported keys per entry:
#   path        (required) - full path to the file to manage
#   enabled     (default: False) - True creates/updates the file,
#                                  False (or omitted) removes it
#   createpath  (default: False) - True creates the parent directory
#                                  if it does not already exist
#   owner       (default: root)
#   group       (default: root)
#   dir_mode    (default: '700')
#   file_mode   (default: '600')
#   config      - literal file contents (only needed when enabled: True)
#
# If write_environment is not present in pillar at all, the formula
# takes no action.
#
# IMPORTANT: always quote dir_mode/file_mode, e.g. dir_mode: '0755'.
# YAML 1.1 (what PyYAML/Salt parses) treats an unquoted leading-zero
# number as octal, so `file_mode: 0600` silently becomes the integer
# 384, not the string "0600" -- the file ends up with the wrong
# permissions instead of erroring. Quoting it as '0600' avoids this
# entirely.
########################################################################

{%- from 'ipam.jinja' import ip %}

write_environment:

  # Retired: the salt-master settings and the salt-api password are in
  # pillar/quadlets/rpi-01.sls now (podman's --env-file kept the quotes
  # around the password). enabled: false deletes the old file, which still
  # holds the password, from the host. Drop this entry once a highstate on
  # rpi-01 has run.
  salt-master:
    enabled: false
    path: /etc/containers/systemd/salt-master/.env

  unbound-config:
    enabled: true
    path: /var/lib/containers/storage/volumes/unbound-etc/_data/unbound.conf
    createpath: true
    owner: root
    group: root
    dir_mode: '0755'
    file_mode: '0600'
    config: |
      server:

          # The  verbosity  number, level 0 means no verbosity, only errors.
          # Level 1 gives operational information. Level  2  gives  detailed
          # operational  information. Level 3 gives query level information,
          # output per query.  Level 4 gives  algorithm  level  information.
          # Level 5 logs client identification for cache misses.  Default is
          # level 1.
          verbosity: 2

          interface: {{ ip('hosts:rpi-01:apps:unbound:ipv4') }}
          port: 5335
          do-ip4: yes
          do-udp: yes
          do-tcp: yes

          # May be set to yes if you have IPv6 connectivity
          do-ip6: no

          # You want to leave this to no unless you have *native* IPv6. With 6to4 and
          # Terredo tunnels your web browser should favor IPv4 for the same reasons
          prefer-ip6: no

          # Use this only when you downloaded the list of primary root servers!
          # Read  the  root  hints from this file. Make sure to
          # update root.hints evry 5-6 months.
          root-hints: "/etc/unbound/custom.conf.d/named.root"

          # Trust glue only if it is within the servers authority
          harden-glue: yes

          # Ignore very large queries.
          harden-large-queries: yes

          # Require DNSSEC data for trust-anchored zones, if such data is absent, the zone becomes BOGUS
          # If you want to disable DNSSEC, set harden-dnssec stripped: no
          harden-dnssec-stripped: yes

          # Number of bytes size to advertise as the EDNS reassembly buffer
          # size. This is the value put into  datagrams over UDP towards
          # peers. The actual buffer size is determined by msg-buffer-size
          # (both for TCP and UDP).
          edns-buffer-size: 1232

          # Rotates RRSet order in response (the pseudo-random
          # number is taken from Ensure privacy of local IP
          # ranges the query ID, for speed and thread safety).
          # private-address: 192.168.0.0/16
          rrset-roundrobin: yes

          # Time to live minimum for RRsets and messages in the cache. If the minimum
          # kicks in, the data is cached for longer than the domain owner intended,
          # and thus less queries are made to look up the data. Zero makes sure the
          # data in the cache is as the domain owner intended, higher values,
          # especially more than an hour or so, can lead to trouble as the data in
          # the cache does not match up with the actual data anymore
          cache-min-ttl: 300
          cache-max-ttl: 86400

          # Have unbound attempt to serve old responses from cache with a TTL of 0 in
          # the response without waiting for the actual resolution to finish. The
          # actual resolution answer ends up in the cache later on.
          serve-expired: yes

          # Harden against algorithm downgrade when multiple algorithms are
          # advertised in the DS record.
          harden-algo-downgrade: yes

          # Ignore very small EDNS buffer sizes from queries.
          harden-short-bufsize: yes

          # Refuse id.server and hostname.bind queries
          hide-identity: yes

          # Report this identity rather than the hostname of the server.
          identity: "Server"

          # Refuse version.server and version.bind queries
          hide-version: yes

          # Prevent the unbound server from forking into the background as a daemon
          do-daemonize: no

          # Number  of  bytes size of the aggressive negative cache.
          neg-cache-size: 4m

          # Send minimum amount of information to upstream servers to enhance privacy
          qname-minimisation: yes

          # Deny queries of type ANY with an empty response.
          # Works only on version 1.8 and above
          deny-any: yes

          # Do no insert authority/additional sections into response messages when
          # those sections are not required. This reduces response size
          # significantly, and may avoid TCP fallback for some responses. This may
          # cause a slight speedup
          minimal-responses: yes

          # Perform prefetching of close to expired message cache entries
          # This only applies to domains that have been frequently queried
          # This flag updates the cached domains
          prefetch: yes

          # Fetch the DNSKEYs earlier in the validation process, when a DS record is
          # encountered. This lowers the latency of requests at the expense of little
          # more CPU usage.
          prefetch-key: yes

          # One thread should be sufficient, can be increased on beefy machines. In reality for
          # most users running on small networks or on a single machine, it should be unnecessary
          # to seek performance enhancement by increasing num-threads above 1.
          num-threads: 1

          # more cache memory. rrset-cache-size should twice what msg-cache-size is.
          msg-cache-size: 50m
          rrset-cache-size: 100m

          # Faster UDP with multithreading (only on Linux).
          so-reuseport: yes

          # Ensure kernel buffer is large enough to not lose messages in traffix spikes
          so-rcvbuf: 4m
          so-sndbuf: 4m

          # Set the total number of unwanted replies to keep track of in every thread.
          # When it reaches the threshold, a defensive action of clearing the rrset
          # and message caches is taken, hopefully flushing away any poison.
          # Unbound suggests a value of 10 million.
          unwanted-reply-threshold: 100000

          #Use 0x20-encoded random bits in the  query  to  foil  spoof  at-
          #tempts.   This  perturbs  the  lowercase  and uppercase of query
          #names sent to authority servers and checks if  the  reply  still
          #has  the  correct casing.  Disabled by default.  This feature is
          #an experimental implementation of draft dns-0x20.
          use-caps-for-id: yes

          # Minimize logs
          # Do not print one line per query to the log
          #log-queries: no
          # Do not print one line per reply to the log
          #log-replies: no
          # Do not print log lines that say why queries return SERVFAIL to clients
          #log-servfail: no
          # Do not print log lines to inform about local zone actions
          #log-local-actions: no
          # Do not print log lines that say why queries return SERVFAIL to clients
          #logfile: /dev/null

          # Ensure privacy of local IP ranges
          private-address: 192.168.0.0/16
          private-address: 169.254.0.0/16
          private-address: 172.16.0.0/12
          private-address: 10.0.0.0/8
          private-address: fd42::/8
          private-address: fd00::/8
          private-address: fe80::/10

  salt-master-haproxy-config:
    enabled: true
    path: /var/lib/containers/storage/volumes/salt-master-haproxy/_data/haproxy.cfg
    createpath: true
    owner: '99'
    group: '99'
    dir_mode: '0755'
    file_mode: '0600'
    config: |
      # HAProxy TLS front for SaltGUI / salt-api.
      #
      # Runs in the same pod as salt-master, so salt-api is reached on 127.0.0.1:8000.
      # The certificate is the podman secret "saltgui-tls" mounted at
      # /usr/local/etc/haproxy/certs/saltgui.pem (certificate + chain, then private key).
      # HAProxy refuses to start if that file is missing.

      global
          log stdout format raw local0

          # Mozilla "intermediate" TLS profile
          ssl-default-bind-curves X25519:prime256v1:secp384r1
          ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305{# noqa 204 #}
          ssl-default-bind-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
          ssl-default-bind-options prefer-client-ciphers ssl-min-ver TLSv1.2 no-tls-tickets

      defaults
          mode http
          log global
          option httplog
          option forwardfor
          timeout connect 5s
          timeout http-request 10s
          timeout http-keep-alive 10s
          # SaltGUI keeps a server-sent-events stream (/events) open that carries no
          # keepalives; short client/server timeouts would cut it.
          timeout client 1h
          timeout server 1h
          # salt-api websockets (/ws)
          timeout tunnel 1h

      frontend http_in
          bind :80
          http-request redirect scheme https code 301

      frontend https_in
          bind :443 ssl crt /usr/local/etc/haproxy/certs/saltgui.pem alpn h2,http/1.1
          http-request set-header X-Forwarded-Proto https
          http-response set-header Strict-Transport-Security "max-age=31536000"
          default_backend saltgui

      backend saltgui
          server saltapi 127.0.0.1:8000 check
