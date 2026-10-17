# -*- coding: utf-8 -*-
# vim: ft=sls
#
# Removes quadlets this formula wrote earlier but which are no longer in
# pillar (or whose app is marked `absent: true`). Only files carrying the
# formula's marker header are touched; hand-written quadlets in the same
# directories are left alone. Services are stopped before their unit files
# disappear, and all of this happens before new containers start, so a
# re-used IP or MAC is free. An app subdirectory is removed once it held
# nothing but such orphans.
{%- from tpldir ~ '/map.jinja' import quadlet, q_marker, q_absent, q_expected, q_app_dirs with context %}
{%- set config_dir = quadlet.config_dir | string %}

include:
  - .config

{%- set orphans = [] %}
{%- set orphan_dirs = [] %}
{%- if salt['file.directory_exists'](config_dir) %}
{%-   for path in salt['file.find'](config_dir, type='f', maxdepth=2, regex='.*\\.(container|volume|network|pod)$') | sort %}
{%-     set rel = path[config_dir | length + 1:] %}
{%-     if rel not in q_expected and salt['file.search'](path, '^' ~ q_marker | regex_escape) %}
{%-       set stem, kind = rel.split('/')[-1].rsplit('.', 1) %}
{%-       set svc = salt['file.read'](path) | regex_search('(?m)^ServiceName=(\\S+)') %}
{%-       if svc %}
{%-         set service = svc[0] ~ '.service' %}
{%-       elif kind == 'container' %}
{%-         set service = stem ~ '.service' %}
{%-       else %}
{%-         set service = stem ~ '-' ~ kind ~ '.service' %}
{%-       endif %}
{%-       do orphans.append({'path': path, 'rel': rel, 'stem': stem, 'kind': kind, 'service': service}) %}
{%-     endif %}
{%-   endfor %}

{%-   set orphan_paths = orphans | map(attribute='path') | list %}
{%-   for d in salt['file.find'](config_dir, type='d', mindepth=1, maxdepth=1) | sort %}
{%-     set files = salt['file.find'](d, type='f') %}
{%-     if salt['file.basename'](d) not in q_app_dirs and files and files | reject('in', orphan_paths) | list | length == 0 %}
{%-       do orphan_dirs.append(d) %}
{%-     endif %}
{%-   endfor %}
{%- endif %}

{%- for o in orphans %}
{%-   if quadlet.manage_services %}

quadlet-orphan-{{ o.rel }}-stop:
  service.dead:
    - name: {{ o.service }}
    - require_in:
      - file: quadlet-orphan-{{ o.rel }}
{%-   endif %}

quadlet-orphan-{{ o.rel }}:
  file.absent:
    - name: {{ o.path }}
{%-   if quadlet.manage_services %}
    - onchanges_in:
      - cmd: quadlet-daemon-reload

{#-   a network unit the formula owned (e.g. after renaming the network) #}
{%-     if o.kind == 'network' %}

quadlet-orphan-{{ o.rel }}-remove:
  cmd.run:
    - name: podman network rm -f {{ o.stem }}
    - onlyif: podman network exists {{ o.stem }}
    - require:
      - service: quadlet-orphan-{{ o.rel }}-stop
{%-     endif %}
{%-   endif %}
{%- endfor %}

{%- for d in orphan_dirs %}

quadlet-orphan-dir-{{ d }}:
  file.absent:
    - name: {{ d }}
    - require:
{%-   for o in orphans if o.path.startswith(d ~ '/') %}
      - file: quadlet-orphan-{{ o.rel }}
{%-   endfor %}
{%- endfor %}

{#- Secrets of an absent app are removed. Data of named volumes is kept
    unless the app says purge_volumes. #}
{%- if quadlet.manage_services %}
{%-   for app in q_absent %}
{%-     set stops = [] %}
{%-     for o in orphans if o.kind in ['container', 'pod'] and o.rel.startswith(app.name ~ '/') %}
{%-       do stops.append(o) %}
{%-     endfor %}
{%-     for s in app.secrets %}

quadlet-absent-{{ app.name }}-secret-{{ s.name }}:
  cmd.run:
    - name: podman secret rm {{ s.name }}
    - onlyif: podman secret exists {{ s.name }}
{%-       if stops %}
    - require:
{%-         for o in stops %}
      - service: quadlet-orphan-{{ o.rel }}-stop
{%-         endfor %}
{%-       endif %}
{%-     endfor %}
{%-     for v in (app.volumes if app.purge_volumes else []) %}

quadlet-absent-{{ app.name }}-purge-{{ v.volume_name }}:
  cmd.run:
    - name: podman volume rm -f {{ v.volume_name }}
    - onlyif: podman volume exists {{ v.volume_name }}
{%-       if stops %}
    - require:
{%-         for o in stops %}
      - service: quadlet-orphan-{{ o.rel }}-stop
{%-         endfor %}
{%-       endif %}
{%-     endfor %}
{%-   endfor %}
{%- endif %}
