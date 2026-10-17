# -*- coding: utf-8 -*-
# vim: ft=yaml
#
# Example pillar for the quadlet formula. Only `network.parent`,
# `network.subnet` and `apps.<app>.containers.<name>.image` are required.
---
quadlets:
  # manage_package: true
  # manage_services: true
  # config_dir: /etc/containers/systemd   # apps go to <config_dir>/<app>/
  # pull_images: true

  # The macvlan network all apps share
  network:
    name: lan                     # lan.network -> podman network "lan"
    parent: eth0                  # host NIC (or a VLAN like eth0.20 / bond0.20)
    mode: bridge                  # optional macvlan mode
    subnet: 192.168.10.0/24
    gateway: 192.168.10.1
    ip_range: 192.168.10.240/28   # optional pool for apps without a static ip
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

  # Merged into the raw sections of every pod
  # pod_defaults:
  #   Install:
  #     WantedBy: multi-user.target

  apps:
    # Single container, no pod:
    # -> /etc/containers/systemd/web/{web.container,web-html.volume}
    #    web.service, container "web"
    web:
      ip: 192.168.10.50
      mac: '02:42:c0:a8:0a:32'    # always quote MACs
      volumes:
        html: {}                  # -> web-html.volume, podman volume "web-html"
      containers:
        web:
          image: docker.io/library/nginx:1.27
          environment:
            NGINX_HOST: web.example.lan
          volumes:
            - volume: html
              target: /usr/share/nginx/html
              options: Z
            # Host directory, created if missing
            - source: /srv/web/conf.d
              target: /etc/nginx/conf.d
              options: [ro, Z]
              mode: '0755'
            # Raw podman --volume syntax is passed through unchanged
            - /etc/localtime:/etc/localtime:ro

    # Several containers -> one pod sharing ip, mac, hostname and localhost:
    # -> /etc/containers/systemd/nextcloud/
    #      nextcloud.pod               nextcloud-pod.service, pod "nextcloud"
    #      nextcloud-app.container     nextcloud-app.service
    #      nextcloud-db.container      nextcloud-db.service
    #      nextcloud-data.volume, nextcloud-db.volume
    nextcloud:
      description: Nextcloud
      ip: 192.168.10.53
      mac: auto                   # derived from ip -> 02:42:c0:a8:0a:35
      hostname: cloud
      dns: [192.168.10.1]
      volumes:
        data: {}
        db:
          volume_name: nextcloud-db-legacy   # adopt an existing podman volume
      # podman secrets (global names); the value is never written to a unit
      secrets:
        nextcloud-db-pass: {{ salt['onepassword.read']('op://infra/nextcloud/db-password') | yaml_dquote }}
      containers:
        app:
          image: docker.io/library/nextcloud:31
          environment:
            MYSQL_HOST: 127.0.0.1           # containers in a pod share localhost
            MYSQL_USER: 'nc$user%1'         # $ and % stay literal
          volumes:
            - volume: data
              target: /var/www/html
          Container:
            Secret: nextcloud-db-pass,type=env,target=MYSQL_PASSWORD
        db:
          image: docker.io/library/mariadb:11
          volumes:
            - volume: db
              target: /var/lib/mysql
          # Raw sections: any capitalized key is written as-is into that section
          Container:
            AddCapability: [SYS_NICE]
            Secret: nextcloud-db-pass,type=env,target=MARIADB_PASSWORD
          Unit:
            Description: Nextcloud database
      # Raw sections on the app go into the .pod unit
      Pod:
        PodmanArgs: --label=app=nextcloud

    nas-backup:
      ip: 192.168.10.60
      mac: '02:00:00:00:10:60'
      running: false              # unit files present, services stopped
      enabled: false              # no [Install], not started at boot
      volumes:
        data:
          Volume:                 # raw [Volume] keys for the .volume unit
            Device: //nas.lan/backup
            Type: cifs
            Options: credentials=/etc/nas-cred,uid=0,gid=0
      containers:
        nas-backup:
          image: docker.io/library/alpine:3.22
          command: sleep infinity
          volumes:
            - volume: data
              target: /data
            - source: /srv/backup/scripts
              target: /scripts
              user: root
              group: root
              mode: '0700'

    # Removed: services stopped, unit files and the app directory deleted.
    # Named volume data is kept unless purge_volumes is true. Simply deleting
    # the entry from pillar also removes the app (without purging).
    old-app:
      absent: true
      purge_volumes: true
      volumes:
        data: {}
