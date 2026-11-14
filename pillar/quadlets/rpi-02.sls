# -*- coding: utf-8 -*-
# vim: ft=yaml
#
# Quadlets on rpi-02: Unbound, netboot.xyz and Grafana on the shared macvlan
# network. Pi-hole is defined but disabled.
# Schema: salt/quadlets/README.md
# Addresses: pillar/ipam.yaml
{%- from 'ipam.jinja' import ip, mac %}
{#- Image tags, pinned to specific versions. Renovate (renovate.json) opens a
    pull request when a newer one is out; the renovate: comment above each
    variable names the image its tag belongs to. A
    changed tag is pulled and its containers restarted on the next highstate;
    raise a version here to upgrade. podman auto-update
    (container_defaults: auto_update: registry) only looks for a newer image
    under the same tag, so it only picks up rebuilds of the pinned version. #}
{#- pihole is disabled below; same version as on rpi-01 #}
{#- renovate: depName=docker.io/pihole/pihole #}
{%- set pihole_version = '2026.11.0' %}
{#- renovate: depName=docker.io/klutchell/unbound #}
{%- set unbound_version = '1.24.2' %}
{#- renovate: depName=ghcr.io/netbootxyz/netbootxyz #}
{%- set netbootxyz_version = '0.7.6-nbxyz27' %}
{#- grafana: a nightly build from grafana-dev (what grafana:main pointed to).
    For a stable version switch the image to docker.io/grafana/grafana with
    a release tag. #}
{#- renovate: depName=docker.io/grafana/grafana-dev #}
{%- set grafana_version = '13.1.0-25957875840' %}
{#- renovate: depName=docker.io/library/haproxy #}
{%- set haproxy_version = '3.4.7' %}
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
    recreate_on_change: true

  container_defaults:
    auto_update: registry         # pairs with podman-auto-update.timer

  apps:
    # -> /etc/containers/systemd/pihole/{pihole.container,pihole-*.volume}
    #    pihole.service, container "pihole"
    # pihole is disabled. It sits in a Jinja comment instead of YAML "#"
    # comments because Jinja runs the 1Password read and the ipam lookups
    # inside YAML comments too. To enable it, delete the two Jinja comment
    # marker lines around it.
    {#- pihole disabled
    pihole:
      description: Pi-hole DNS
      hostname: pihole-03
      ip: {{ ip('hosts:rpi-02:apps:pihole:ipv4') }}
      mac: "{{ mac('hosts:rpi-02:apps:pihole:mac') }}"
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
    #}

    # -> /etc/containers/systemd/unbound/{unbound.container,unbound-etc.volume}
    #    unbound.service, container "unbound"
    # -> /etc/systemd/system/unbound-root-hints.{service,timer}
    unbound:
      description: Unbound recursive DNS resolver
      ip: {{ ip('hosts:rpi-02:apps:unbound:ipv4') }}
      ip6: {{ ip('hosts:rpi-02:apps:unbound:ipv6') }}
      mac: "{{ mac('hosts:rpi-02:apps:unbound:mac') }}"
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
          # Upstream, like rpi-01 and rpi-03. Was hub.klessen.cloud/klutchell/unbound,
          # which that registry no longer has.
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

    # -> /etc/containers/systemd/netbootxyz/{netbootxyz.container,netbootxyz-*.volume}
    #    netbootxyz.service, container "netbootxyz"
    netbootxyz:
      description: netboot.xyz PXE boot server (TFTP, menu editor, asset mirror)
      hostname: netboot
      ip: {{ ip('hosts:rpi-02:apps:netbootxyz:ipv4') }}
      ip6: {{ ip('hosts:rpi-02:apps:netbootxyz:ipv6') }}
      mac: "{{ mac('hosts:rpi-02:apps:netbootxyz:mac') }}"
      # podman volumes netbootxyz-config (menus, web app settings) and
      # netbootxyz-assets (mirrored ISOs/kernels, can grow large)
      volumes:
        config:
          Volume:
            Label: app=netbootxyz
        assets:
          Volume:
            Label: app=netbootxyz
      containers:
        netbootxyz:
          image: ghcr.io/netbootxyz/netbootxyz:{{ netbootxyz_version }}
          environment:
            # TFTP answers from port 69 instead of random high ports. Not
            # needed on macvlan (no NAT), but keeps firewall rules simple.
            TFTPD_OPTS: '--tftp-single-port'
            # pin the netboot.xyz menu release (unset = latest)
            # MENU_VERSION: '2.0.84'
          volumes:
            - volume: config
              target: /config
            - volume: assets
              target: /assets
          # No PublishPort: on macvlan the container answers on its own IP
          # with TFTP 69/udp, web UI 3000/tcp, assets 80/tcp.

    # -> /etc/containers/systemd/grafana/{grafana.pod, grafana.container,
    #      grafana-haproxy.container, grafana-{data,haproxy}.volume}
    #    pod "grafana" (grafana-pod.service), containers grafana
    #    (grafana.service) and grafana-haproxy. haproxy terminates TLS on 443
    #    (80 redirects to https) and forwards to grafana on 127.0.0.1:3000 in
    #    the same pod.
    grafana:
      description: Grafana
      ip: {{ ip('hosts:rpi-02:apps:grafana:ipv4') }}
      ip6: {{ ip('hosts:rpi-02:apps:grafana:ipv6') }}
      mac: "{{ mac('hosts:rpi-02:apps:grafana:mac') }}"
      # Has no effect on macvlan (the pod answers on its own IP); kept from
      # the original unit. The web UI is https on port 443 (haproxy below);
      # grafana itself only listens on 127.0.0.1:3000.
      #Pod:
      #  PublishPort: '3000:3000/tcp'
      # podman volumes grafana-data / grafana-haproxy, on the host under
      # /var/lib/containers/storage/volumes/grafana-*/_data
      volumes:
        data:
          Volume:
            Driver: local
            GlobalArgs: --log-level=debug
            User: 472                 # grafana user in the image
            Group: 1000
            Label: app=grafana
        # haproxy.cfg (write_environment) and the TLS certificate (acme_sh),
        # both written on the host and owned by root
        haproxy:
          Volume:
            Driver: local
            Label: app=grafana
      # podman secret "grafana", created on the host by the formula
      secrets:
        grafana: {{ salt['onepassword.read']('op://infra/grafana/password') | yaml_dquote }}   # keep quoted
      containers:
        grafana:
          description: Grafana
          # Nightly build of grafana's main branch, see grafana_version at the
          # top of this file.
          image: docker.io/grafana/grafana-dev:{{ grafana_version }}
          environment:
            # Only read when grafana creates its database on the first start;
            # a new value later does not change the admin password.
            GF_SECURITY_ADMIN_PASSWORD__FILE: /run/secrets/admin_password
            # Only haproxy (same pod) talks to grafana; the LAN gets TLS on
            # 443 and no plain HTTP port.
            GF_SERVER_HTTP_ADDR: 127.0.0.1
            # Public URL behind haproxy, for redirects and links. The name
            # must match the certificate (pillar/acme_sh/rpi-02.sls).
            GF_SERVER_ROOT_URL: https://grafana.mgmt.gz.klessen.cloud/
          volumes:
            - volume: data
              target: /var/lib/grafana
          Container:
            AddCapability: [CAP_NET_BIND_SERVICE, CAP_NET_RAW]
            # the app secret above as the file /run/secrets/admin_password
            Secret: grafana,type=mount,target=admin_password

        # TLS in front of the web UI: port 443 (IPv4 and IPv6) on the pod's
        # address -> 127.0.0.1:3000; port 80 redirects to https. haproxy.cfg
        # and the certificate are in the haproxy volume.
        haproxy:
          description: Grafana HAProxy
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
