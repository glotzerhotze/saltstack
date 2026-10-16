# -*- coding: utf-8 -*-
# vim: ft=sls
#
# One .container unit per pillar entry, plus a .volume unit per named volume
# and host directories for bind mounts.
{%- from tpldir ~ '/map.jinja' import quadlet, q_marker, q_containers with context %}

include:
  - .network

{%- for c in q_containers %}
{%-   set prefix = 'quadlet-container-' ~ c.name %}

{%-   for d in c.bind_dirs %}

{{ prefix }}-bind-{{ d.path }}:
  file.directory:
    - name: {{ d.path }}
    - makedirs: True
{%-     if d.user is not none %}
    - user: {{ d.user }}
{%-     endif %}
{%-     if d.group is not none %}
    - group: {{ d.group }}
{%-     endif %}
{%-     if d.mode is not none %}
    - mode: '{{ d.mode }}'
{%-     endif %}
{%-   endfor %}

{%-   for v in c.named_volumes %}

{{ prefix }}-volume-{{ v.unit }}:
  file.managed:
    - name: {{ v.file }}
    - source: salt://{{ tpldir }}/files/unit.jinja
    - template: jinja
    - user: root
    - group: root
    - mode: '0644'
    - context: {{ {'marker': q_marker, 'sections': v.sections} | json }}
    - require:
      - file: quadlet-config-dir
{%-     if quadlet.manage_services %}
    - onchanges_in:
      - cmd: quadlet-daemon-reload
{%-     endif %}
{%-   endfor %}

{{ prefix }}-file:
  file.managed:
    - name: {{ c.file }}
    - source: salt://{{ tpldir }}/files/unit.jinja
    - template: jinja
    - user: root
    - group: root
    - mode: '0644'
    - context: {{ {'marker': q_marker, 'sections': c.sections} | json }}
    - require:
      - file: quadlet-network-file
{%-   for v in c.named_volumes %}
      - file: {{ prefix }}-volume-{{ v.unit }}
{%-   endfor %}
{%-   if quadlet.manage_services %}
    - onchanges_in:
      - cmd: quadlet-daemon-reload
{%-   endif %}

{%-   if quadlet.manage_services %}
{%-     if c.pull %}

{{ prefix }}-pull:
  cmd.run:
    - name: podman pull {{ c.image }}
    - unless: podman image exists {{ c.image }}
{%-       if quadlet.manage_package %}
    - require:
      - pkg: quadlet-package-installed
{%-       endif %}
{%-     endif %}

{{ prefix }}-service:
{%-     if c.running %}
  service.running:
{%-     else %}
  service.dead:
{%-     endif %}
    - name: {{ c.service }}
    - require:
      - cmd: quadlet-daemon-reload
      - service: quadlet-network-service
{%-     if c.pull %}
      - cmd: {{ prefix }}-pull
{%-     endif %}
{%-     for d in c.bind_dirs %}
      - file: {{ prefix }}-bind-{{ d.path }}
{%-     endfor %}
{%-     if c.running %}
    {#- network changes reach the container via Requires= on the network service #}
    - watch:
      - file: {{ prefix }}-file
{%-       for v in c.named_volumes %}
      - file: {{ prefix }}-volume-{{ v.unit }}
{%-       endfor %}
{%-     endif %}
{%-   endif %}
{%- endfor %}
