# -*- coding: utf-8 -*-
# vim: ft=sls
#
# The shared macvlan network every quadlet is attached to.
{%- from tpldir ~ '/map.jinja' import quadlet, q_marker, q_network with context %}
{%- set net = q_network %}

include:
  - .config

quadlet-network-file:
  file.managed:
    - name: {{ net.file }}
    - source: salt://{{ tpldir }}/files/unit.jinja
    - template: jinja
    - user: root
    - group: root
    - mode: '0644'
    - context: {{ {'marker': q_marker, 'sections': net.sections} | json }}
    - require:
      - file: quadlet-config-dir
{%- if quadlet.manage_services %}
    - onchanges_in:
      - cmd: quadlet-daemon-reload

{#- Quadlet runs `podman network create --ignore`, so an existing network never
    picks up changed settings. When the unit file changes, stop everything
    attached (systemd propagates the stop through Requires=) and drop the
    network so it is re-created from the new file. Skipped on first rollout so
    a pre-existing network of the same name is never removed. #}
{%-   if quadlet.network.recreate_on_change and salt['file.file_exists'](net.file) %}

quadlet-network-recreate:
  cmd.run:
    - name: systemctl stop {{ net.service }} || true; podman network rm -f {{ net.name }}
    - onlyif: podman network exists {{ net.name }}
    - onchanges:
      - file: quadlet-network-file
    - require_in:
      - cmd: quadlet-daemon-reload
{%-   endif %}

quadlet-network-service:
  service.running:
    - name: {{ net.service }}
    - require:
      - cmd: quadlet-daemon-reload
    - watch:
      - file: quadlet-network-file
{%- endif %}
