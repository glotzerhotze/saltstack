# -*- coding: utf-8 -*-
# vim: ft=yaml
#
# Quadlets on server-01: the container registry (distribution), its docker
# mirror, paperless-ngx, influxdb and immich on the shared macvlan network.
# Schema: salt/quadlets/README.md
# Addresses: pillar/ipam.yaml
{%- from 'ipam.jinja' import ip, mac %}
{#- Image tags, pinned to specific versions. Renovate (renovate.json) opens a
    pull request when a newer one is out; the renovate: comment above each
    variable names the image its tag belongs to. A
    changed tag is pulled and its containers restarted on the next highstate;
    raise a version here to upgrade. podman auto-update (tika's
    auto_update: registry) only looks for a newer image under the same tag,
    so it only picks up rebuilds of the pinned version. #}
{#- registry and registry-mirror #}
{#- renovate: depName=docker.io/library/registry #}
{%- set registry_version = '3.1.2' %}
{#- paperless-ngx pod; gotenberg needs 8.13+ for --api-bind-ip, and tika's
    start command below is copied from the image (check it when raising
    paperless_tika_version) #}
{#- renovate: depName=ghcr.io/paperless-ngx/paperless-ngx #}
{%- set paperless_version = '3.4.2' %}
{#- renovate: depName=docker.io/library/redis #}
{%- set paperless_redis_version = '8.10.3' %}
{#- renovate: depName=docker.io/gotenberg/gotenberg #}
{%- set paperless_gotenberg_version = '8.40.0' %}
{#- renovate: depName=docker.io/apache/tika #}
{%- set paperless_tika_version = '3.3.3.0-full' %}
{#- The 3.x images hold a single jar named after the Tika version, which is
    the tag without the image build number and suffix (3.3.3.0-full ->
    /tika-server-standard-3.3.3.jar). 4.x images use /opt/tika-server/
    instead; see the tika container below. #}
{%- set paperless_tika_jar = '/tika-server-standard-' ~ (paperless_tika_version.split('-')[0].split('.')[:3] | join('.')) ~ '.jar' %}
{#- Stay on 2.x: InfluxDB 3 has a different storage engine and is no
    in-place upgrade #}
{#- renovate: depName=docker.io/library/influxdb #}
{%- set influxdb_version = '2.9.1' %}
{#- TLS proxy in the paperless-ngx, influxdb and immich pods #}
{#- renovate: depName=docker.io/library/haproxy #}
{%- set haproxy_version = '3.4.7' %}
{#- Immich release for server and machine-learning, which must match. Read
    the release notes before raising it: https://github.com/immich-app/immich/releases #}
{#- renovate: depName=ghcr.io/immich-app/immich-server #}
{%- set immich_version = 'v3.4.2' %}
{#- valkey and postgres for immich: tag and digest from the upstream
    docker-compose.yml of that release, so update them together with
    immich_version:
    https://github.com/immich-app/immich/releases/download/<version>/docker-compose.yml #}
{#- renovate: depName=docker.io/valkey/valkey #}
{%- set immich_valkey_version = '9@sha256:1c2b25b09f354c66fe994733acdf12fcfd4bdf6f3bd92b88a93a70378d884056' %}
{#- renovate: depName=ghcr.io/immich-app/postgres #}
{%- set immich_postgres_version = '14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23' %}
---
quadlets:
  network:
    name: macvlan                 # macvlan.network -> podman network "macvlan"
    parent: enp0s31f6             # same as PodmanArgs=--interface-name=enp0s31f6
    # dual stack: IPv4 + ULA IPv6
    ipv6: true
    subnet:
      - {{ ip('networks:mgmt:ipv4:subnet') }}
      - {{ ip('networks:mgmt:ipv6:subnet') }}
    gateway:
      - {{ ip('networks:mgmt:ipv4:gateway') }}
      - {{ ip('networks:mgmt:ipv6:gateway') }}
    Network:
      Label: role=public
    recreate_on_change: true

  apps:
    # -> /etc/containers/systemd/registry/{registry.container,registry-*.volume}
    #    registry.service, container "registry"
    registry:
      description: Container registry (distribution)
      ip: {{ ip('hosts:server-01:apps:registry:ipv4') }}
      # Pinned like the other apps (see pillar/ipam.yaml). Without it podman
      # picks the first free address of the subnet, which a container on
      # another host may already use.
      ip6: {{ ip('hosts:server-01:apps:registry:ipv6') }}
      mac: "{{ mac('hosts:server-01:apps:registry:mac') }}"
      # podman volumes registry-config / registry-data, on the host under
      # /var/lib/containers/storage/volumes/registry-*/_data
      volumes:
        config:
          Volume: &registry_volume
            Driver: local
            GlobalArgs: --log-level=debug
            User: 1000
            Group: 1000
            Label: app=registry
        data:
          Volume: *registry_volume
      containers:
        registry:
          image: docker.io/library/registry:{{ registry_version }}
          environment:
            REGISTRY_HTTP_ADDR: "{{ ip('hosts:server-01:apps:registry:ipv4') }}:443"
            # TODO: create certificates and put them inside the config volume
            # DONE: see acme_sh formula and pillar
            #       (/var/lib/containers/storage/volumes/registry-config/_data/)
            REGISTRY_HTTP_TLS_CERTIFICATE: /etc/distribution/fullchain.cer
            # TODO: change the name of the key to match your specific cert names
            REGISTRY_HTTP_TLS_KEY: /etc/distribution/hub.klessen.cloud.key
          volumes:
            - volume: config
              target: /etc/distribution
            - volume: data
              target: /var/lib/registry
          Container:
            # Has no effect on macvlan (the container answers on its own IP);
            # kept from the original unit.
            #PublishPort: '443:443/tcp'

    registry-mirror:
      description: Container registry (distribution) - docker mirror
      ip: {{ ip('hosts:server-01:apps:registry-mirror:ipv4') }}
      # Pinned like the other apps (see pillar/ipam.yaml). Without it podman
      # picks the first free address of the subnet, which a container on
      # another host may already use.
      ip6: {{ ip('hosts:server-01:apps:registry-mirror:ipv6') }}
      mac: "{{ mac('hosts:server-01:apps:registry-mirror:mac') }}"
      # podman volumes registry-config / registry-data, on the host under
      # /var/lib/containers/storage/volumes/registry-*/_data
      volumes:
        config:
          Volume: &registry-mirror_volume
            Driver: local
            GlobalArgs: --log-level=debug
            User: 1000
            Group: 1000
            Label: app=registry
        data:
          Volume: *registry-mirror_volume
      containers:
        registry-mirror:
          image: docker.io/library/registry:{{ registry_version }}
          environment:
            REGISTRY_HTTP_ADDR: "{{ ip('hosts:server-01:apps:registry-mirror:ipv4') }}:443"
            # TODO: create certificates and put them inside the config volume
            #       (/var/lib/containers/storage/volumes/registry-mirror-config/_data/)
            REGISTRY_HTTP_TLS_CERTIFICATE: /etc/distribution/fullchain.cer
            # TODO: change the name of the key to match your specific cert names
            REGISTRY_HTTP_TLS_KEY: /etc/distribution/docker.klessen.cloud.key
          volumes:
            - volume: config
              target: /etc/distribution
            - volume: data
              target: /var/lib/registry
          Container:
            # Has no effect on macvlan (the container answers on its own IP);
            # kept from the original unit.
            #PublishPort: '443:443/tcp'

    # -> /etc/containers/systemd/paperless-ngx/{paperless-ngx.pod,
    #      paperless-ngx-{app,redis,gotenberg,tika,haproxy}.container,
    #      paperless-ngx-{data,media,export,consume,redis,haproxy}.volume}
    #    pod "paperless-ngx" (paperless-ngx-pod.service), containers
    #    paperless-ngx-app / -redis / -gotenberg / -tika / -haproxy. They share
    #    the pod's network namespace, so the app reaches redis, tika and
    #    gotenberg on localhost, and haproxy reaches the app on 127.0.0.1:8000.
    paperless-ngx:
      description: Paperless-NGX Pod
      ip: {{ ip('hosts:server-01:apps:paperless-ngx:ipv4') }}
      # Pinned like the other apps (see pillar/ipam.yaml). Without it podman
      # picks the first free address of the subnet, which a container on
      # another host may already use.
      ip6: {{ ip('hosts:server-01:apps:paperless-ngx:ipv6') }}
      mac: "{{ mac('hosts:server-01:apps:paperless-ngx:mac') }}"
      # Has no effect on macvlan (the pod answers on its own IP); kept from
      # the original unit. The web UI is https on port 443 (haproxy below);
      # paperless itself only listens on 127.0.0.1:8000.
      #Pod:
      #  PublishPort: '8000:8000'
      # podman volumes paperless-ngx-data / -media / -export / -consume /
      # -redis / -haproxy, on the host under
      # /var/lib/containers/storage/volumes/paperless-ngx-*/_data
      volumes:
        data:
          Volume: &paperless_ngx_volume
            Driver: local
            GlobalArgs: --log-level=debug
            User: 2000
            Group: 2000
            Label: app=paperless-ngx
        media:
          Volume: *paperless_ngx_volume
        export:
          Volume: *paperless_ngx_volume
        consume:
          Volume: *paperless_ngx_volume
        redis:
          Volume: *paperless_ngx_volume
        # haproxy.cfg (write_environment) and the TLS certificate (acme_sh),
        # both written on the host and owned by root
        haproxy:
          Volume:
            Driver: local
            Label: app=paperless-ngx
      # podman secret "paperless-ngx", created on the host by the formula
      secrets:
        paperless-ngx: {{ salt['onepassword.read']('op://infra/paperless-ngx/secret_key') | yaml_dquote }}
        paperless-gmail-secret: {{ salt['onepassword.read']('op://infra/paperless-ngx-google-app/client-secret') | yaml_dquote }}   # keep quoted
      containers:
        app:
          description: Paperless-NGX Application
          image: ghcr.io/paperless-ngx/paperless-ngx:{{ paperless_version }}
          # auto_update: registry
          # Written into the .container unit, so a changed value restarts the
          # app. PAPERLESS_SECRET_KEY comes from the app secret above.
          environment:
            USERMAP_UID: '2000'           # owner of the volumes above
            USERMAP_GID: '2000'
            # redis, tika and gotenberg run in the same pod
            PAPERLESS_REDIS: redis://127.0.0.1:6379
            PAPERLESS_TIKA_ENABLED: '1'
            PAPERLESS_TIKA_GOTENBERG_ENDPOINT: http://127.0.0.1:3000
            PAPERLESS_TIKA_ENDPOINT: http://127.0.0.1:9998
            PAPERLESS_TIME_ZONE: Europe/Berlin
            PAPERLESS_OCR_LANGUAGE: deu+eng
            PAPERLESS_OCR_USER_ARGS: '{"invalidate_digital_signatures": true}'
            # https: served by haproxy on 443. Django's CSRF check compares the
            # browser's Origin with this URL, so http:// would break the login.
            # The name must match the certificate (pillar/acme_sh/server-01.sls).
            PAPERLESS_URL: https://paperless-ngx.mgmt.gz.klessen.cloud
            PAPERLESS_ALLOWED_HOSTS: paperless-ngx.mgmt.gz.klessen.cloud
            PAPERLESS_MAIL_TASK_CRON: disable
            PAPERLESS_DATE_PARSER_LANGUAGES: de
            PAPERLESS_CONSUMER_RECURSIVE: 'true'
            PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS: 'true'
            PAPERLESS_CONSUMER_ENABLE_ASN_BARCODE: 'true'
            PAPERLESS_CONSUMER_DELETE_DUPLICATES: 'true'
            PAPERLESS_GMAIL_OAUTH_CLIENT_ID: '318310645322-jlvsdv4j5ksr83df8nmjfu6v7afu0vej.apps.googleusercontent.com'
            PAPERLESS_EMAIL_TASK_CRON: '*/5 * * * *'
            # PAPERLESS_POST_CONSUME_SCRIPT: ''
            # Only haproxy (same pod) talks to the web server; the LAN gets
            # TLS on 443 and no plain HTTP port.
            PAPERLESS_BIND_ADDR: 127.0.0.1
            # raw block: the placeholders are for paperless, not for the
            # pillar render
            PAPERLESS_FILENAME_FORMAT: '{% raw %}{{ created_year }}{{ created_month }}{{ created_day }}-{{ title }}{% endraw %}'
          Container:
            # from the app secret above; a new value restarts the container
            Secret:
              - paperless-ngx,type=env,target=PAPERLESS_SECRET_KEY
              - paperless-gmail-secret,type=env,target=PAPERLESS_GMAIL_OAUTH_CLIENT_SECRET
          volumes:
            - volume: data
              target: /usr/src/paperless/data
              options: Z
            - volume: media
              target: /usr/src/paperless/media
              options: Z
            - volume: export
              target: /usr/src/paperless/export
              options: Z
            - volume: consume
              target: /usr/src/paperless/consume
              options: Z
          Unit:
            After: [paperless-ngx-redis.service, paperless-ngx-tika.service, paperless-ngx-gotenberg.service]

        redis:
          description: Paperless Redis
          image: docker.io/library/redis:{{ paperless_redis_version }}
          # loopback only: the pod's macvlan address is reachable from the LAN
          command: 'redis-server --bind 127.0.0.1'

          volumes:
            - volume: redis
              target: /data
              options: Z

        gotenberg:
          description: Paperless Gotenberg
          image: docker.io/gotenberg/gotenberg:{{ paperless_gotenberg_version }}
          # loopback only (--api-bind-ip needs 8.13+): the pod's macvlan address is reachable from the LAN
          #command: 'gotenberg --chromium-disable-javascript=true --chromium-allow-list=file:///tmp/.*'
          command: 'gotenberg --chromium-disable-javascript=true --chromium-allow-list=file:///tmp/.* --api-bind-ip=127.0.0.1'

        tika:
          description: Paperless Tika
          image: docker.io/apache/tika:{{ paperless_tika_version }}
          auto_update: registry
          # loopback only: the pod's macvlan address is reachable from the LAN.
          # The image's entrypoint hard-codes "-h 0.0.0.0" and Tika uses the first -h it
          # sees, so this repeats the image's start command (as of 3.3.3.0-full) with
          # 127.0.0.1. The image expands ${TIKA_VERSION} in a shell; Entrypoint=java
          # has none, so the jar path comes from paperless_tika_jar above. 4.x images
          # need '-cp /opt/tika-server/*:/opt/tika-server/lib/*:/tika-extras/*' instead.
          # lowercase formula option -> Entrypoint=java. A capitalized key here
          # would be read as a raw unit section ([Entrypoint]) and break the render.
          entrypoint: java
          command: '-cp {{ paperless_tika_jar }}:/tika-extras/* org.apache.tika.server.core.TikaServerCli -h 127.0.0.1'

        # TLS in front of the web UI: port 443 (IPv4 and IPv6) on the pod's
        # address -> 127.0.0.1:8000; port 80 redirects to https. haproxy.cfg
        # and the certificate are in the haproxy volume.
        haproxy:
          description: Paperless HAProxy
          image: docker.io/library/haproxy:{{ haproxy_version }}
          # The image runs as the unprivileged user haproxy, which may not
          # bind ports 80 and 443. haproxy starts as root, binds the ports,
          # reads the key and then switches to that user (user/group in
          # haproxy.cfg).
          user: root
          volumes:
            - volume: haproxy
              target: /usr/local/etc/haproxy
              options: [ro, Z]

    # -> /etc/containers/systemd/influxdb/{influxdb.pod, influxdb.container,
    #      influxdb-haproxy.container, influxdb-{data,config,haproxy}.volume}
    #    pod "influxdb" (influxdb-pod.service), containers influxdb /
    #    influxdb-haproxy. haproxy reaches influxd on 127.0.0.1:8086 in the
    #    pod's network namespace.
    influxdb:
      description: InfluxDB 2 Pod
      ip: {{ ip('hosts:server-01:apps:influxdb:ipv4') }}
      # Pinned like the other apps (see pillar/ipam.yaml). Without it podman
      # picks the first free address of the subnet, which a container on
      # another host may already use.
      ip6: {{ ip('hosts:server-01:apps:influxdb:ipv6') }}
      mac: "{{ mac('hosts:server-01:apps:influxdb:mac') }}"
      # podman volumes influxdb-data / -config / -haproxy, on the host under
      # /var/lib/containers/storage/volumes/influxdb-*/_data. The image's
      # entrypoint chowns data and config to its influxdb user (1000:1000).
      volumes:
        data:
          Volume: &influxdb_volume
            Driver: local
            Label: app=influxdb
        config:
          Volume: *influxdb_volume
        # haproxy.cfg (write_environment) and the TLS certificate (acme_sh),
        # both written on the host and owned by root
        haproxy:
          Volume: *influxdb_volume
      # podman secrets "influxdb-password" / "influxdb-token", created on the
      # host by the formula
      secrets:
        influxdb-password: {{ salt['onepassword.read']('op://infra/influxdb/password') | yaml_dquote }}   # keep quoted
        influxdb-token: {{ salt['onepassword.read']('op://infra/influxdb/token') | yaml_dquote }}   # keep quoted
      containers:
        influxdb:
          description: InfluxDB 2
          image: docker.io/library/influxdb:{{ influxdb_version }}
          environment:
            # First start only: the entrypoint runs the setup while
            # influxd.bolt does not exist yet. New values later change
            # nothing; manage users, orgs, buckets and tokens in the UI or
            # with the influx CLI.
            DOCKER_INFLUXDB_INIT_MODE: setup
            DOCKER_INFLUXDB_INIT_USERNAME: admin
            DOCKER_INFLUXDB_INIT_PASSWORD_FILE: /run/secrets/influxdb-password
            DOCKER_INFLUXDB_INIT_ADMIN_TOKEN_FILE: /run/secrets/influxdb-token
            DOCKER_INFLUXDB_INIT_ORG: home
            # No DOCKER_INFLUXDB_INIT_RETENTION: the bucket keeps data forever
            DOCKER_INFLUXDB_INIT_BUCKET: telegraf
            # Only haproxy (same pod) talks to influxd; the LAN gets TLS on
            # 443 and no plain HTTP port.
            INFLUXD_HTTP_BIND_ADDRESS: 127.0.0.1:8086
            # No usage statistics to InfluxData
            INFLUXD_REPORTING_DISABLED: 'true'
          Container:
            # the app secrets above as files in /run/secrets, read as root by
            # the entrypoint before it drops to the influxdb user
            Secret:
              - influxdb-password,type=mount,target=influxdb-password
              - influxdb-token,type=mount,target=influxdb-token
          volumes:
            - volume: data
              target: /var/lib/influxdb2
              options: Z
            - volume: config
              target: /etc/influxdb2
              options: Z

        # TLS in front of influxd (web UI and API): port 443 (IPv4 and IPv6)
        # on the pod's address -> 127.0.0.1:8086; port 80 redirects to https.
        # haproxy.cfg and the certificate are in the haproxy volume.
        influxdb-haproxy:
          description: InfluxDB HAProxy
          image: docker.io/library/haproxy:{{ haproxy_version }}
          # The image runs as the unprivileged user haproxy, which may not
          # bind ports 80 and 443. haproxy starts as root, binds the ports,
          # reads the key and then switches to that user (user/group in
          # haproxy.cfg).
          user: root
          volumes:
            - volume: haproxy
              target: /usr/local/etc/haproxy
              options: [ro, Z]

    # -> /etc/containers/systemd/immich/{immich.pod,
    #      immich-{server,machine-learning,redis,database,haproxy}.container,
    #      immich-{library,postgres,model-cache,haproxy}.volume}
    #    pod "immich" (immich-pod.service), containers immich-server /
    #    -machine-learning / -redis / -database / -haproxy. They share the
    #    pod's network namespace, so the server reaches postgres, valkey and
    #    machine learning on 127.0.0.1, and haproxy reaches the server on
    #    127.0.0.1:2283. Only haproxy (80/443) listens on the pod's address.
    #    Built from the upstream docker-compose.yml of the release above:
    #    https://github.com/immich-app/immich/releases/download/<version>/docker-compose.yml
    immich:
      description: Immich Pod
      ip: {{ ip('hosts:server-01:apps:immich:ipv4') }}
      # Pinned like the other apps (see pillar/ipam.yaml). Without it podman
      # picks the first free address of the subnet, which a container on
      # another host may already use.
      ip6: {{ ip('hosts:server-01:apps:immich:ipv6') }}
      mac: "{{ mac('hosts:server-01:apps:immich:mac') }}"
      Pod:
        # /dev/shm of the pod. The containers share it (IPC namespace), so
        # it is set here and not on the database container. Upstream gives
        # postgres shm_size: 128mb.
        PodmanArgs: --shm-size=128m
      # podman volumes immich-library / -postgres / -model-cache / -haproxy,
      # on the host under /var/lib/containers/storage/volumes/immich-*/_data.
      # The images run as root and set up their own ownership.
      volumes:
        # Photos and videos, thumbnails, transcoded videos and Immich's own
        # nightly database dumps (backups/). This is the one that grows.
        library:
          Volume: &immich_volume
            Driver: local
            Label: app=immich
        # postgres data directory; must not be on a network share
        postgres:
          Volume: *immich_volume
        # machine learning models, downloaded on first use
        model-cache:
          Volume: *immich_volume
        # haproxy.cfg (write_environment) and the TLS certificate (acme_sh),
        # both written on the host and owned by root
        haproxy:
          Volume: *immich_volume
      # podman secret "immich-db-password", created on the host by the
      # formula. Upstream asks for A-Za-z0-9 only. postgres reads it once,
      # when it creates the database: changing it in 1Password later locks
      # the server out until the role gets the same password
      # (ALTER USER postgres PASSWORD '...').
      secrets:
        immich-db-password: {{ salt['onepassword.read']('op://infra/immich/db_password') | yaml_dquote }}   # keep quoted
      containers:
        server:
          description: Immich Server
          # A new version is pulled and the containers restarted on the next
          # highstate; Immich migrates the database at start.
          image: ghcr.io/immich-app/immich-server:{{ immich_version }}
          environment:
            TZ: Europe/Berlin
            # Only haproxy (same pod) talks to the web UI and API; the LAN
            # gets TLS on 443 and no plain port 2283.
            IMMICH_HOST: 127.0.0.1
            # postgres, valkey and machine learning run in the same pod
            DB_HOSTNAME: 127.0.0.1
            DB_USERNAME: postgres
            DB_DATABASE_NAME: immich
            REDIS_HOSTNAME: 127.0.0.1
            IMMICH_MACHINE_LEARNING_URL: http://127.0.0.1:3003
            # haproxy, so the logs and sessions show the client's address
            IMMICH_TRUSTED_PROXIES: 127.0.0.1
          Container:
            # from the app secret above; a new value restarts the container
            Secret: immich-db-password,type=env,target=DB_PASSWORD
            # Hardware transcoding (Quick Sync / VA-API): pass the GPU in,
            # then pick it under Administration > Video Transcoding Settings.
            #AddDevice: /dev/dri
          volumes:
            - source: /mnt/base/archive-2/immich
              target: /data
              options: Z
            - /etc/localtime:/etc/localtime:ro
          Unit:
            After: [immich-database.service, immich-redis.service, immich-machine-learning.service]
          Service:
            # postgres needs a few seconds on the first start (initdb), and
            # the server exits while it can't connect. Spaced restarts stay
            # below systemd's start limit (5 starts in 10 s).
            RestartSec: 10

        machine-learning:
          description: Immich Machine Learning
          # must be the same release as the server
          image: ghcr.io/immich-app/immich-machine-learning:{{ immich_version }}
          environment:
            TZ: Europe/Berlin
            # only the server (same pod) uses it
            IMMICH_HOST: 127.0.0.1
          volumes:
            - volume: model-cache
              target: /cache
              options: Z

        redis:
          description: Immich Valkey
          # tag and digest from the upstream docker-compose.yml of the release
          image: docker.io/valkey/valkey:{{ immich_valkey_version }}
          # The image turns protected mode off, so without --bind valkey
          # would take unauthenticated connections on the pod's address. The
          # job queue lives in memory only, as upstream.
          command: valkey-server --bind 127.0.0.1

        database:
          description: Immich PostgreSQL
          # tag and digest from the upstream docker-compose.yml of the
          # release; Immich only supports the vector extensions it ships
          image: ghcr.io/immich-app/postgres:{{ immich_postgres_version }}
          # The image's CMD plus listen_addresses: only the server (same pod)
          # connects, so port 5432 stays off the pod's address. The
          # healthcheck uses the unix socket.
          command: postgres -c config_file=/etc/postgresql/postgresql.conf -c listen_addresses=127.0.0.1
          environment:
            # First start only (initdb), like the password below
            POSTGRES_USER: postgres
            POSTGRES_DB: immich
            POSTGRES_INITDB_ARGS: '--data-checksums'
            # Uncomment if the volume is not on an SSD
            #DB_STORAGE_TYPE: HDD
          Container:
            # from the app secret above
            Secret: immich-db-password,type=env,target=POSTGRES_PASSWORD
          volumes:
            - volume: postgres
              target: /var/lib/postgresql/data
              options: Z

        # TLS in front of the web UI and API: port 443 (IPv4 and IPv6) on the
        # pod's address -> 127.0.0.1:2283; port 80 redirects to https.
        # haproxy.cfg and the certificate are in the haproxy volume.
        haproxy:
          description: Immich HAProxy
          image: docker.io/library/haproxy:{{ haproxy_version }}
          # The image runs as the unprivileged user haproxy, which may not
          # bind ports 80 and 443. haproxy starts as root, binds the ports,
          # reads the key and then switches to that user (user/group in
          # haproxy.cfg).
          user: root
          volumes:
            - volume: haproxy
              target: /usr/local/etc/haproxy
              options: [ro, Z]
