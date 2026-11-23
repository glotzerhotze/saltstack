# -*- coding: utf-8 -*-
# vim: ft=yaml
#
# Quadlets on rpi-01: the Salt master (cdalvaro/docker-salt-master), Pi-hole
# and Unbound on the shared macvlan network.
# Schema: salt/quadlets/README.md
# Addresses: pillar/ipam.yaml
{%- from 'ipam.jinja' import ip, mac %}
{#- Image tags, pinned to specific versions. Renovate (renovate.json) opens a
    pull request when a newer one is out; the renovate: comment above each
    variable names the image its tag belongs to. A
    changed tag is pulled and its container restarted on the next highstate;
    raise a version here to upgrade. #}
{#- Salt master: pin a version tag you have validated #}
{#- renovate: depName=hub.klessen.cloud/glotzerhotze/docker-salt-master #}
{%- set salt_master_version = '3008.5-gui' %}
{#- renovate: depName=docker.io/pihole/pihole #}
{%- set pihole_version = '2026.11.0' %}
{#- renovate: depName=docker.io/klutchell/unbound #}
{%- set unbound_version = '1.26.2' %}
{#- TLS proxy in the salt-master pod #}
{#- renovate: depName=docker.io/library/haproxy #}
{%- set haproxy_version = '3.4.8-alpine' %}
---
quadlets:
  network:
    name: macvlan                 # macvlan.network -> podman network "macvlan"
    parent: eth0                  # same as PodmanArgs=--interface-name=eth0
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
    # The Salt master runs on this network. Re-creating it stops every
    # attached container, which would take the master down in the middle of
    # the highstate that changed the .network unit. Podman keeps the existing
    # network instead; re-create it by hand when its settings change.
    recreate_on_change: false

  apps:
    # -> /etc/containers/systemd/salt-master/{salt-master.pod,
    #      salt-master-{app,haproxy}.container,
    #      salt-master-{srv,keys,logs,config,3pfs,haproxy}.volume}
    #    pod "salt-master" (salt-master-pod.service, which scripts/deploy.sh
    #    restarts), containers salt-master-app / -haproxy. haproxy terminates
    #    TLS for SaltGUI on 443 (80 redirects to https) and reaches salt-api on
    #    127.0.0.1:8000 in the pod's network namespace (config/20-salt-api.conf).
    #    No PublishPort: on macvlan 4505/4506 are reachable on the pod's ip.
    salt-master:
      description: Salt master with SaltGUI behind HAProxy
      hostname: salt-master
      ip: {{ ip('hosts:rpi-01:apps:salt-master:ipv4') }}
      mac: "{{ mac('hosts:rpi-01:apps:salt-master:mac') }}"
      Pod:
        # lets haproxy bind 80 and 443 as its unprivileged image user (uid 99)
        PodmanArgs: --sysctl=net.ipv4.ip_unprivileged_port_start=80
      # podman volumes salt-master-srv / -keys / -logs / -config / -3pfs, the
      # same names scripts/deploy.sh rsyncs into, and salt-master-haproxy with
      # haproxy.cfg (write_environment) and the TLS certificate (acme_sh)
      volumes:
        srv:
          Volume: &salt_master_volume
            Label: app=salt-master
        keys:
          Volume: *salt_master_volume
        logs:
          Volume: *salt_master_volume
        config:
          Volume: *salt_master_volume
        3pfs:
          Volume: *salt_master_volume
        haproxy:
          Volume: *salt_master_volume
      # podman secret "salt-api-pass", created on the host by the formula
      secrets:
        salt-api-pass: {{ salt['onepassword.read']('op://infra/salt-master/password') | yaml_dquote }}   # keep quoted
      containers:
        app:
          description: Salt master with SaltGUI
          image: hub.klessen.cloud/glotzerhotze/docker-salt-master:{{ salt_master_version }}
          # command: salt-master -l debug
          # Not the .env file from write_environment: podman's --env-file
          # keeps the quotes around its values, which would end up in the
          # password.
          environment:
            TZ: Europe/Berlin
            SALT_RESTART_MASTER_ON_CONFIG_CHANGE: 'true'
            SALT_LOG_LEVEL: info
            SALT_LEVEL_LOGFILE: debug
            SALT_API_ENABLED: 'true'
            # must match the user under external_auth in config/20-salt-api.conf
            SALT_API_USER: saltgui
            SALT_MINION_ENABLED: 'true'
            SALT_MINION_ID: test-minion
            PUID: '1000'
            PGID: '1000'
          Container:
            # SaltGUI / salt-api password from the app secret above; a new
            # value restarts the container
            Secret: salt-api-pass,type=env,target=SALT_API_USER_PASS
            HealthCmd: /usr/local/sbin/healthcheck
            HealthStartPeriod: 30s
          volumes:
            - volume: srv
              target: /home/salt/data/srv
              options: Z
            - volume: keys
              target: /home/salt/data/keys
              options: Z
            - volume: logs
              target: /home/salt/data/logs
              options: Z
            - volume: config
              target: /home/salt/data/config
              options: Z
            - volume: 3pfs
              target: /home/salt/data/3pfs
              options: Z
          Unit:
            Wants: network-online.target
            After: network-online.target
          Service:
            # the first start may need to pull the image
            TimeoutStartSec: 300

        # TLS in front of SaltGUI / salt-api: port 443 on the pod's address ->
        # 127.0.0.1:8000; port 80 redirects to https. haproxy.cfg and the
        # certificate are in the haproxy volume.
        haproxy:
          description: HAProxy TLS front for SaltGUI
          image: docker.io/library/haproxy:{{ haproxy_version }}
          # Runs as the image's haproxy user (uid 99), which owns haproxy.cfg
          # and the certificate (write_environment, acme_sh). The pod's sysctl
          # above lets it bind 80 and 443, so unlike the haproxy containers on
          # server-01 and rpi-02 it needs no user: root.
          volumes:
            - volume: haproxy
              target: /usr/local/etc/haproxy
              options: [ro, Z]
          Unit:
            After: salt-master-app.service

    # -> /etc/containers/systemd/pihole/{pihole.container,pihole-*.volume}
    #    pihole.service, container "pihole"
    pihole:
      description: Pi-hole DNS
      hostname: pihole-01
      ip: {{ ip('hosts:rpi-01:apps:pihole:ipv4') }}
      ip6: {{ ip('hosts:rpi-01:apps:pihole:ipv6') }}
      mac: "{{ mac('hosts:rpi-01:apps:pihole:mac') }}"
      # podman volumes pihole-etc / pihole-dnsmasq / pihole-logs
      volumes:
        etc:
          Volume: &pihole_volume
            User: 1000
            Group: 1000
            Label: app=pihole
        dnsmasq:
          Volume: *pihole_volume
        logs:
          Volume: *pihole_volume
      # podman secret "pihole", created on the host by the formula
      secrets:
        pihole: {{ salt['onepassword.read']('op://infra/pihole/password') | yaml_dquote }}   # keep quoted
      containers:
        pihole:
          image: docker.io/pihole/pihole:{{ pihole_version }}
          environment:
            TZ: Europe/Berlin
            # name on the Let's Encrypt certificate in /etc/pihole/tls.pem
            # (acme_sh/rpi-01.sls); validity 0 keeps FTL from replacing it
            # with a self-signed one
            FTLCONF_webserver_domain: ph-01.mgmt.gz.klessen.cloud
            FTLCONF_webserver_tls_validity: '0'
          volumes:
            - volume: etc
              target: /etc/pihole
              options: Z
            - volume: dnsmasq
              target: /etc/dnsmasq.d
              options: Z
            - volume: logs
              target: /var/log/pihole
              options: Z
          Container:
            AddCapability: [CAP_NET_BIND_SERVICE, CAP_NET_RAW, CAP_NET_ADMIN, CAP_SYS_NICE, CAP_CHOWN, CAP_SYS_TIME]
            # web UI / API password from the app secret above
            Secret: pihole,type=env,target=FTLCONF_webserver_api_password
            # Has no effect on macvlan (the container answers on its own IP);
            # kept from the original unit.
            PublishPort:
              - 53:53/tcp
              - 53:53/udp
              - 80:80/tcp
              - 443:443/tcp

    # -> /etc/containers/systemd/unbound/{unbound.container,unbound-etc.volume}
    #    unbound.service, container "unbound"
    # -> /etc/systemd/system/unbound-root-hints.{service,timer}
    unbound:
      description: Unbound recursive DNS resolver
      ip: {{ ip('hosts:rpi-01:apps:unbound:ipv4') }}
      ip6: {{ ip('hosts:rpi-01:apps:unbound:ipv6') }}
      mac: "{{ mac('hosts:rpi-01:apps:unbound:mac') }}"
      # podman volume unbound-etc
      volumes:
        etc:
          Volume:
            User: 101
            Group: 102
            Label: app=unbound
      # Daily refresh of the DNS root hints into the volume. unbound reads
      # them at start, so a refreshed file takes effect on its next restart.
      units:
        unbound-root-hints.service:
          Unit:
            Description: Download DNS root hints for unbound
            Requires: unbound-etc-volume.service
            After: [unbound-etc-volume.service, network-online.target]
            Wants: network-online.target
          Service:
            Type: oneshot
            # --resolve avoids needing DNS; the temp file keeps a failed
            # download from replacing a good named.root
            ExecStart:
              - /usr/bin/curl --fail --silent --show-error --resolve www.internic.net:443:192.0.46.9 -o /var/lib/containers/storage/volumes/unbound-etc/_data/named.root.tmp https://www.internic.net/domain/named.root
              - /usr/bin/mv -f /var/lib/containers/storage/volumes/unbound-etc/_data/named.root.tmp /var/lib/containers/storage/volumes/unbound-etc/_data/named.root
        unbound-root-hints.timer:
          Unit:
            Description: Daily refresh of the unbound root hints
          Timer:
            OnCalendar: daily
            RandomizedDelaySec: 1h
            Persistent: true
          Install:
            WantedBy: timers.target
      containers:
        unbound:
          image: docker.io/klutchell/unbound:{{ unbound_version }}
          environment:
            TZ: Europe/Berlin
          volumes:
            - volume: etc
              target: /etc/unbound/custom.conf.d
          Container:
            AddCapability: [CAP_NET_BIND_SERVICE, CAP_NET_RAW, CAP_NET_ADMIN, CAP_SYS_NICE, CAP_CHOWN, CAP_SYS_TIME]
            # Has no effect on macvlan (the container answers on its own IP);
            # kept from the original unit.
            PublishPort:
              - '[::]:5335:5335/tcp'
              - '[::]:5335:5335/udp'
          Unit:
            # fetch the root hints before every start, without blocking it
            Wants: unbound-root-hints.service
            After: unbound-root-hints.service
