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

  # Fully-specified example: creates the file, creates the parent
  # directory if needed, and sets explicit owner/group/modes.
  registry-mirror:
    enabled: true
    path: /var/lib/containers/storage/volumes/registry-mirror-config/_data/config.yml
    createpath: true
    owner: root
    group: root
    dir_mode: '0755'
    file_mode: '0600'
    config: |
      # CNCF Distribution registry (registry:3) as a Docker Hub pull-through cache
      # Served at https://docker.klessen.cloud
      # Recipe: https://distribution.github.io/distribution/recipes/mirror/
      # Mounted into the container at /etc/distribution/config.yml

      version: 0.1

      log:
        level: info
        formatter: text
        fields:
          service: registry-mirror

      storage:
        # The recipe recommends the filesystem driver for a pull-through cache
        filesystem:
          rootdirectory: /var/lib/registry
        # Must be enabled, otherwise the scheduler cannot expire cached content (proxy.ttl)
        delete:
          enabled: true
        cache:
          blobdescriptor: inmemory
        maintenance:
          uploadpurging:
            enabled: true
            age: 168h
            interval: 24h
            dryrun: false

      http:
        addr: :443
        host: https://docker.klessen.cloud
        # http.secret is supplied via REGISTRY_HTTP_SECRET (see .env)
        headers:
          X-Content-Type-Options: [nosniff]
        tls:
          minimumtls: tls1.3
          #letsencrypt:
          #  cachefile: /var/lib/registry-acme/cache
          #  # Overridden by REGISTRY_HTTP_TLS_LETSENCRYPT_EMAIL (see .env)
          #  email: admin@klessen.cloud
          #  # Only issue certificates for this hostname (protects against bogus SNI)
          #  hosts: [docker.klessen.cloud]

      health:
        storagedriver:
          enabled: true
          interval: 10s
          threshold: 3

      proxy:
        # Only one upstream per registry instance; Docker daemon mirrors only support Docker Hub
        remoteurl: https://registry-1.docker.io
        # Docker Hub credentials are optional and supplied via
        # REGISTRY_PROXY_USERNAME / REGISTRY_PROXY_PASSWORD (see docker-compose.yml).
        # WARNING: any private image that account can see becomes pullable through this mirror.
        ttl: 168h

  # The paperless settings moved into pillar/quadlets/server-01.sls
  # (apps:paperless-ngx:containers:app:environment). This only removes the
  # old .env from the host; drop the entry once that has run.
  paperless-ngx:
    enabled: false
    path: /etc/containers/systemd/paperless-ngx/.env

  # haproxy in the paperless-ngx pod (pillar/quadlets/server-01.sls): TLS on
  # 443 in front of the web UI, plain http on 80 redirects to https. The
  # certificate paperless-ngx.pem and its key
  # paperless-ngx.pem.key are put into the same volume by the acme_sh formula
  # (pillar/acme_sh/server-01.sls).
  paperless-ngx-haproxy:
    enabled: true
    path: /var/lib/containers/storage/volumes/paperless-ngx-haproxy/_data/haproxy.cfg
    createpath: true
    owner: root
    group: root
    dir_mode: '0755'
    file_mode: '0644'
    config: |
      # Mounted into the container at /usr/local/etc/haproxy/haproxy.cfg

      global
          log stdout format raw local0
          # started as root (User=root in the quadlet) to bind 80/443 and read
          # the key, then switches to the image's unprivileged user
          user haproxy
          group haproxy

      defaults
          mode http
          log global
          option httplog
          option forwardfor
          timeout connect 5s
          timeout http-request 10s
          timeout client 5m
          timeout server 5m
          # websocket for the live status updates in the web UI
          timeout tunnel 1h

      frontend http
          # IPv4 and IPv6; only redirects, keeping host, path and query
          bind [::]:80 v4v6
          http-request redirect scheme https code 301

      frontend https
          # IPv4 and IPv6; the key is loaded from <crt>.key
          bind [::]:443 v4v6 ssl crt /usr/local/etc/haproxy/paperless-ngx.pem alpn h2,http/1.1
          http-request set-header X-Forwarded-Proto https
          default_backend paperless

      backend paperless
          # PAPERLESS_BIND_ADDR=127.0.0.1 in the same pod
          server app 127.0.0.1:8000

  # haproxy in the influxdb pod (pillar/quadlets/server-01.sls): TLS on 443
  # in front of the web UI and the API, plain http on 80 redirects to https.
  # The certificate influxdb.pem and its key influxdb.pem.key are put into
  # the same volume by the acme_sh formula (pillar/acme_sh/server-01.sls).
  influxdb-haproxy:
    enabled: true
    path: /var/lib/containers/storage/volumes/influxdb-haproxy/_data/haproxy.cfg
    createpath: true
    owner: root
    group: root
    dir_mode: '0755'
    file_mode: '0644'
    config: |
      # Mounted into the container at /usr/local/etc/haproxy/haproxy.cfg

      global
          log stdout format raw local0
          # started as root (User=root in the quadlet) to bind 80/443 and read
          # the key, then switches to the image's unprivileged user
          user haproxy
          group haproxy

      defaults
          mode http
          log global
          option httplog
          option forwardfor
          timeout connect 5s
          timeout http-request 10s
          # long-running Flux queries
          timeout client 5m
          timeout server 5m

      frontend http
          # IPv4 and IPv6; only redirects, keeping host, path and query
          bind [::]:80 v4v6
          http-request redirect scheme https code 301

      frontend https
          # IPv4 and IPv6; the key is loaded from <crt>.key
          bind [::]:443 v4v6 ssl crt /usr/local/etc/haproxy/influxdb.pem alpn h2,http/1.1
          http-request set-header X-Forwarded-Proto https
          default_backend influxdb

      backend influxdb
          # INFLUXD_HTTP_BIND_ADDRESS=127.0.0.1:8086 in the same pod
          server influxdb 127.0.0.1:8086

  # haproxy in the immich pod (pillar/quadlets/server-01.sls): TLS on 443 in
  # front of the web UI and the API the mobile apps use, plain http on 80
  # redirects to https. The certificate immich.pem and its key immich.pem.key
  # are put into the same volume by the acme_sh formula
  # (pillar/acme_sh/server-01.sls).
  immich-haproxy:
    enabled: true
    path: /var/lib/containers/storage/volumes/immich-haproxy/_data/haproxy.cfg
    createpath: true
    owner: '99'
    group: '99'
    dir_mode: '0755'
    file_mode: '0644'
    config: |
      #---------------------------------------------------------------------
      # HAProxy configuration for Immich (reverse proxy + TLS termination)
      # Based on https://docs.immich.app/administration/reverse-proxy/
      #
      # Adjust: the domain, certificate path and backend address below.
      #---------------------------------------------------------------------

      global
          log /dev/log local0
          log /dev/log local1 notice
          log stdout format raw local0
          chroot /var/lib/haproxy
          stats socket /run/haproxy/admin.sock mode 660 level admin
          stats timeout 30s
          # started as root (User=root in the quadlet) to bind 80/443 and read
          # the key, then switches to the image's unprivileged user
          user haproxy
          group haproxy
          daemon

          # Modern TLS defaults
          ssl-default-bind-curves X25519:prime256v1
          ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets
          ssl-default-bind-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256
          ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305{# noqa 204 #}

      defaults
          mode http
          log global
          option httplog
          option dontlognull
          option http-keep-alive

          # Docs recommend 600s read/send timeouts so large uploads/downloads
          # (e.g. videos) don't get cut off (HAProxy's equivalent of nginx's
          # proxy_read_timeout / proxy_send_timeout / send_timeout = 600s).
          timeout connect 10s
          timeout client  600s
          timeout server  600s
          timeout http-request 600s
          timeout http-keep-alive 10s

          # WebSocket connections (Immich web UI live updates) stay open
          # idle for long periods; keep the tunnel alive.
          timeout tunnel 1h

      #---------------------------------------------------------------------
      # Frontends
      #---------------------------------------------------------------------

      # Redirect HTTP -> HTTPS (while still allowing Let's Encrypt http-01 for Immich)
      frontend http_in
          bind [::]:80 v4v6
          http-request redirect scheme https code 301 unless { ssl_fc }

      frontend https_in
          # Put your certificate (fullchain + private key concatenated in one PEM)
          # at this path, or point to a directory containing several certs.
          bind [::]:443 v4v6 ssl crt /usr/local/etc/haproxy/immich.pem alpn h2,http/1.1

          # --- Required headers (docs: Host, X-Real-IP, X-Forwarded-Proto, X-Forwarded-For)
          # Host is forwarded unchanged by HAProxy by default.
          # X-Forwarded-For is added by "option forwardfor" in the backend.
          http-request set-header X-Real-IP %[src]
          http-request set-header X-Forwarded-Proto https
          http-request set-header X-Forwarded-Port  %[dst_port]

          # Optional: HSTS
          #http-response set-header Strict-Transport-Security "max-age=63072000"

          # Only serve the Immich hostname (Immich must be at the root of a
          # domain/subdomain - sub-paths are NOT supported).
          acl host_immich hdr(host),field(1,:) -i immich.mgmt.gz.klessen.cloud
          use_backend immich if host_immich

          default_backend immich

      #---------------------------------------------------------------------
      # Backend
      #---------------------------------------------------------------------
      backend immich
          # Adds X-Forwarded-For with the client's address.
          option forwardfor

          # No request body size limit and no request buffering are applied by
          # HAProxy by default (it streams bodies), so large uploads work without
          # extra settings (nginx's client_max_body_size / proxy_request_buffering off).

          # WebSockets: HAProxy proxies Upgrade/Connection headers transparently
          # and switches to tunnel mode (see "timeout tunnel" above).

          # Optional basic health check against Immich's ping endpoint.
          option httpchk
          http-check send meth GET uri /api/server/ping hdr Host immich.mgmt.gz.klessen.cloud
          http-check expect status 200

          # Immich server listens on port 2283. Replace host with your container
          # name / IP address.
          server immich1 127.0.0.1:2283 check inter 10s fall 3 rise 2
