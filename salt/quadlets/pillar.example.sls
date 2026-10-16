# -*- coding: utf-8 -*-
# vim: ft=yaml
#
# Example pillar for the quadlet formula. Only `network.parent`,
# `network.subnet` and `containers.<name>.image` are required.
---
quadlet:
  # manage_package: true
  # manage_services: true
  # config_dir: /etc/containers/systemd
  # pull_images: true

  # The macvlan network all quadlets share
  network:
    name: lan                     # lan.network -> podman network "lan"
    parent: eth0                  # host NIC (or a VLAN like eth0.20 / bond0.20)
    mode: bridge                  # optional macvlan mode
    subnet: 192.168.10.0/24
    gateway: 192.168.10.1
    ip_range: 192.168.10.240/28   # optional pool for quadlets without a static ip
    # ipv6: true
    # subnet: [192.168.10.0/24, 'fd00:10::/64']
    # options:
    #   mtu: 9000
    # recreate_on_change: true
    # Raw [Network]/[Unit]/[Service] keys can be added too:
    # Network:
    #   Label: site=home

  # Merged into every container below (container settings win)
  container_defaults:
    auto_update: registry         # pairs with podman-auto-update.timer
    Service:
      Restart: always
      TimeoutStartSec: 900

  containers:
    # -> /etc/containers/systemd/web.container, web.service, container "web"
    web:
      image: docker.io/library/nginx:1.27
      ip: 192.168.10.50
      mac: '02:42:c0:a8:0a:32'    # always quote MACs
      environment:
        NGINX_HOST: web.example.lan
      volumes:
        # Named podman volume -> web-html.volume, podman volume "web-html"
        - name: html
          target: /usr/share/nginx/html
          options: Z
        # Host directory, created if missing
        - source: /srv/web/conf.d
          target: /etc/nginx/conf.d
          options: [ro, Z]
          mode: '0755'
        # Raw podman --volume syntax is passed through unchanged
        - /etc/localtime:/etc/localtime:ro

    pihole:
      image: docker.io/pihole/pihole:2025.06.2
      ip: 192.168.10.53
      mac: auto                   # derived from ip -> 02:42:c0:a8:0a:35
      hostname: pihole
      dns: [127.0.0.1, 1.1.1.1]
      environment:
        TZ: Europe/Berlin
        FTLCONF_webserver_api_password: 'change$me%now'   # $ and % stay literal
      volumes:
        - name: etc
          target: /etc/pihole
        - name: dnsmasq
          target: /etc/dnsmasq.d
          volume_name: pihole-dnsmasq-legacy   # adopt an existing podman volume
      # Raw sections: any capitalized key is written as-is into that section
      Container:
        AddCapability: [NET_ADMIN, SYS_NICE]
      Unit:
        Description: Pi-hole DNS
        After: web.service

    nas-backup:
      image: docker.io/library/alpine:3.22
      ip: 192.168.10.60
      mac: '02:00:00:00:10:60'
      command: sleep infinity
      running: false              # unit file present, service stopped
      enabled: false              # no [Install], not started at boot
      volumes:
        - name: data
          target: /data
          Volume:                 # raw [Volume] keys for the .volume unit
            Device: //nas.lan/backup
            Type: cifs
            Options: credentials=/etc/nas-cred,uid=0,gid=0
        - source: /srv/backup/scripts
          target: /scripts
          user: root
          group: root
          mode: '0700'

    # Removed: service stopped, unit files deleted. Named volume data is kept
    # unless purge_volumes is true. Simply deleting the entry from pillar
    # also removes the quadlet (without purging).
    old-app:
      absent: true
      purge_volumes: true
      volumes:
        - name: data
          target: /data
