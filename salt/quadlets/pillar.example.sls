# -*- coding: utf-8 -*-
# vim: ft=yaml
#
# Example pillar for the quadlet formula: the live setup on rpi-02
# (pillar/quadlets/rpi-02.sls), Pi-hole and Unbound on a dual-stack macvlan.
# Only `network.parent`, `network.subnet` and
# `apps.<app>.containers.<name>.image` are required. All keys: README.md
---
quadlets:
  # Formula defaults, see defaults.yaml:
  # manage_package: true
  # manage_services: true
  # config_dir: /etc/containers/systemd   # apps go to <config_dir>/<app>/
  # systemd_dir: /etc/systemd/system      # plain units from apps:<app>:units
  # pull_images: true

  network:
    name: macvlan                 # macvlan.network -> podman network "macvlan"
    parent: eth0                  # same as PodmanArgs=--interface-name=eth0
    # dual stack: IPv4 + ULA IPv6
    ipv6: true
    subnet:
      - 192.168.23.0/24
      - fd23:dead:f00d:1::/64
    gateway:
      - 192.168.23.254
      - fd23:dead:f00d:1::1
    Network:
      Label: role=public

  # Merged into every container below (container settings win)
  container_defaults:
    auto_update: registry         # pairs with podman-auto-update.timer

  apps:
    # -> /etc/containers/systemd/pihole/{pihole.container,pihole-*.volume}
    #    pihole.service, container "pihole"
    pihole:
      description: Pi-hole DNS
      hostname: pihole-03
      ip: 192.168.23.32
      mac: '02:ac:1d:fe:ed:20'    # always quote MACs
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
      # podman secret "pihole", created on the host by the formula. In the
      # real pillar the value comes from 1Password (keep it quoted):
      #   pihole: salt['onepassword.read']('op://infra/pihole/password') | yaml_dquote
      # wrapped in a Jinja expression.
      secrets:
        pihole: "<from 1Password: op://infra/pihole/password>"
      containers:
        pihole:
          image: docker.io/pihole/pihole:latest
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
          # Raw sections: any capitalized key is written as-is into that section
          Container:
            AddCapability: [CAP_NET_BIND_SERVICE, CAP_NET_RAW, CAP_NET_ADMIN, CAP_SYS_NICE, CAP_CHOWN, CAP_SYS_TIME]
            # web UI / API password from the app secret above
            Secret: pihole,type=env,target=FTLCONF_webserver_api_password
            # Has no effect on macvlan (the container answers on its own IP)
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
      ip: 192.168.23.144
      mac: 'de:ad:c0:ff:ee:90'
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
          image: hub.klessen.cloud/klutchell/unbound:main
          environment:
            TZ: Europe/Berlin
          volumes:
            - volume: etc
              target: /etc/unbound/custom.conf.d
          Container:
            AddCapability: [CAP_NET_BIND_SERVICE, CAP_NET_RAW, CAP_NET_ADMIN, CAP_SYS_NICE, CAP_CHOWN, CAP_SYS_TIME]
            # Has no effect on macvlan (the container answers on its own IP)
            PublishPort:
              - '[::]:5335:5335/tcp'
              - '[::]:5335:5335/udp'
          Unit:
            # fetch the root hints before every start, without blocking it
            Wants: unbound-root-hints.service
            After: unbound-root-hints.service
