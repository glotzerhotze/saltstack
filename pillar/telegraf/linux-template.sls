# -*- coding: utf-8 -*-
# vim: ft=yaml
#
# Telegraf with the configuration of InfluxData's "Linux System Monitoring"
# community template:
# https://github.com/influxdata/community-templates/blob/master/linux_system/linux_system.yml
# The same [agent] settings and the same nine inputs, writing to the InfluxDB
# on server-01 (pillar/quadlets/server-01.sls) instead of the template's
# $INFLUX_HOST / $INFLUX_ORG placeholders.
# Schema: 3pfs/telegraf-formula/pillar.example; the options of each plugin
# are the ones its files/<kind>/<plugin>.conf template reads.
---
telegraf:
  # telegraf.repo (included by the `telegraf` state) would add its own
  # InfluxData source with signed-by=/etc/apt/keyrings/influxdata-archive.gpg.
  # apt refuses one source with two different Signed-By values, and the apt
  # formula's clean_sources_list_d would delete that file anyway. Pointing it
  # at the source the apt formula already writes makes the state find it
  # configured and change nothing.
  # Keep this in sync with repositories:influxdata in pillar/apt/common.sls.
  repo:
    name: deb [signed-by=/etc/apt/keyrings/influxdata-archive.asc] https://repos.influxdata.com/debian/ stable main
    file: /etc/apt/sources.list.d/influxdata-binary.list

  agent:
    enabled: true

    # [agent] as in the template
    interval: 10s
    round_interval: true
    metric_batch_size: 1000
    metric_buffer_limit: 10000
    collection_jitter: 0s
    flush_interval: 10s
    flush_jitter: 0s
    precision: ''
    hostname: ''                  # empty: telegraf tags metrics with the OS hostname
    omit_hostname: false

    # telegraf.d/input-<name>.conf; `true` means no options, as in the template
    input:
      cpu:
        percpu: true
        totalcpu: true
        collect_cpu_time: false
        report_active: false
      disk:
        ignore_fs: [tmpfs, devtmpfs, devfs, iso9660, overlay, aufs, squashfs]
      diskio: true
      kernel: true
      mem: true
      net: true
      swap: true
      system: true
      dns_query:
        servers: [ "192.168.23.3", "192.168.23.33" ]
      docker:
        endpoint: "unix:///run/podman/podman.sock"
        source_tag: true
      linux_cpu: true
      linux_sysctl_fs: true
      netstat: true
      processes:
        use_sudo: true
      socketstat: true
      systemd_units:
        unittype: "service, timer"
        scope: system
        collect_disabled_units: false
        details: true
        timeout: "5s"
    output:
      influxdb_v2:
        # haproxy in the influxdb pod, Let's Encrypt certificate
        urls:
          - https://influxdb.mgmt.gz.klessen.cloud
        # Like the template, read from the environment (write_environment
        # below): telegraf.d files are world-readable, and Salt would show
        # the value in diffs.
        token: '${INFLUX_TOKEN}'
        organization: home
        bucket: telegraf
