# -*- coding: utf-8 -*-
# vim: ft=sls
#
# Removes quadlets this formula wrote earlier but which are no longer in
# pillar (or are marked `absent: true`). Only files carrying the formula's
# marker header are touched; hand-written quadlets in the same directory are
# left alone. Services are stopped before their unit files disappear, and all
# of this happens before new containers start, so a re-used IP or MAC is free.
{%- from tpldir ~ '/map.jinja' import quadlet, q_marker, q_absent, q_expected with context %}
{%- set config_dir = quadlet.config_dir %}
{%- set absent_names = q_absent | map(attribute='name') | list %}

include:
  - .config

{%- set orphans = [] %}
{%- if salt['file.directory_exists'](config_dir) %}
{%-   for path in salt['file.find'](config_dir, type='f', maxdepth=1, regex='.*\\.(container|volume|network)$') | sort %}
{%-     set base = salt['file.basename'](path) %}
{%-     if base not in q_expected and salt['file.search'](path, '^' ~ q_marker | regex_escape) %}
{%-       set stem, kind = base.rsplit('.', 1) %}
{%-       set svc = salt['file.read'](path) | regex_search('(?m)^ServiceName=(\\S+)') %}
{%-       if svc %}
{%-         set service = svc[0] ~ '.service' %}
{%-       elif kind == 'container' %}
{%-         set service = stem ~ '.service' %}
{%-       else %}
{%-         set service = stem ~ '-' ~ kind ~ '.service' %}
{%-       endif %}
{%-       do orphans.append({'path': path, 'base': base, 'stem': stem, 'kind': kind, 'service': service}) %}
{%-     endif %}
{%-   endfor %}
{%- endif %}

{%- for o in orphans %}
{%-   if quadlet.manage_services %}

quadlet-orphan-{{ o.base }}-stop:
  service.dead:
    - name: {{ o.service }}
    - require_in:
      - file: quadlet-orphan-{{ o.base }}
{%-   endif %}

quadlet-orphan-{{ o.base }}:
  file.absent:
    - name: {{ o.path }}
{%-   if quadlet.manage_services %}
    - onchanges_in:
      - cmd: quadlet-daemon-reload

{#-   a network unit the formula owned (e.g. after renaming the network) #}
{%-     if o.kind == 'network' %}

quadlet-orphan-{{ o.base }}-remove:
  cmd.run:
    - name: podman network rm -f {{ o.stem }}
    - onlyif: podman network exists {{ o.stem }}
    - require:
      - service: quadlet-orphan-{{ o.base }}-stop
{%-     endif %}
{%-   endif %}
{%- endfor %}

{#- Data of named volumes is kept unless the container says purge_volumes. #}
{%- if quadlet.manage_services %}
{%-   for c in q_absent if c.purge_volumes %}
{%-     for v in c.named_volumes %}

quadlet-absent-{{ c.name }}-purge-{{ v.volume_name }}:
  cmd.run:
    - name: podman volume rm -f {{ v.volume_name }}
    - onlyif: podman volume exists {{ v.volume_name }}
{%-       if (c.name ~ '.container') in orphans | map(attribute='base') | list %}
    - require:
      - service: quadlet-orphan-{{ c.name }}.container-stop
{%-       endif %}
{%-     endfor %}
{%-   endfor %}
{%- endif %}
