# -*- coding: utf-8 -*-
# vim: ft=yaml
#
# Quadlets on rpi-03: Pi-hole and Unbound on the shared macvlan network.
# Schema: salt/quadlets/README.md
# Addresses: pillar/ipam.yaml
{%- from 'ipam.jinja' import ip, mac %}
{#- Image tags, pinned to specific versions. Renovate (renovate.json) opens a
    pull request when a newer one is out; the renovate: comment above each
    variable names the image its tag belongs to. A
    changed tag is pulled and its container restarted on the next highstate;
    raise a version here to upgrade. podman auto-update
    (container_defaults: auto_update: registry) only looks for a newer image
    under the same tag, so it only picks up rebuilds of the pinned version. #}
{#- renovate: depName=docker.io/pihole/pihole #}
{%- set pihole_version = '2026.11.0' %}
{#- renovate: depName=docker.io/klutchell/unbound #}
{%- set unbound_version = '1.26.1' %}
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
    pihole:
      description: Pi-hole DNS
      hostname: pihole-02
      ip: {{ ip('hosts:rpi-03:apps:pihole:ipv4') }}
      ip6: {{ ip('hosts:rpi-03:apps:pihole:ipv6') }}
      mac: "{{ mac('hosts:rpi-03:apps:pihole:mac') }}"
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
        pihole: {{ salt['onepassword.read']('op://infra/pihole/password') | yaml_dquote }}
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

    # -> /etc/containers/systemd/unbound/{unbound.container,unbound-etc.volume}
    #    unbound.service, container "unbound"
    # -> /etc/systemd/system/unbound-root-hints.{service,timer}
    unbound:
      description: Unbound recursive DNS resolver
      ip: {{ ip('hosts:rpi-03:apps:unbound:ipv4') }}
      ip6: {{ ip('hosts:rpi-03:apps:unbound:ipv6') }}
      mac: "{{ mac('hosts:rpi-03:apps:unbound:mac') }}"
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
