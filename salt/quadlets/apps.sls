# -*- coding: utf-8 -*-
# vim: ft=sls
#
# One subdirectory per app under config_dir, holding its .volume units, its
# .pod unit (when the containers share a pod) and one .container unit per
# container, plus host directories for bind mounts.
{%- from tpldir ~ '/map.jinja' import quadlet, q_marker, q_apps with context %}

include:
  - .network

{%- for app in q_apps %}
{%-   set prefix = 'quadlet-app-' ~ app.name %}

{{ prefix }}-dir:
  file.directory:
    - name: {{ app.dir }}
    - user: root
    - group: root
    - mode: '0755'
    - require:
      - file: quadlet-config-dir

{%-   for v in app.volumes %}

{{ prefix }}-volume-{{ v.name }}:
  file.managed:
    - name: {{ v.file }}
    - source: salt://{{ tpldir }}/files/unit.jinja
    - template: jinja
    - user: root
    - group: root
    - mode: '0644'
    - context: {{ {'marker': q_marker, 'sections': v.sections} | json }}
    - require:
      - file: {{ prefix }}-dir
{%-     if quadlet.manage_services %}
    - onchanges_in:
      - cmd: quadlet-daemon-reload
{%-     endif %}
{%-   endfor %}

{%-   if app.pod %}

{{ prefix }}-pod:
  file.managed:
    - name: {{ app.pod.file }}
    - source: salt://{{ tpldir }}/files/unit.jinja
    - template: jinja
    - user: root
    - group: root
    - mode: '0644'
    - context: {{ {'marker': q_marker, 'sections': app.pod.sections} | json }}
    - require:
      - file: {{ prefix }}-dir
      - file: quadlet-network-file
{%-     if quadlet.manage_services %}
    - onchanges_in:
      - cmd: quadlet-daemon-reload
{%-     endif %}
{%-   endif %}

{%-   for c in app.containers %}
{%-     set cprefix = prefix ~ '-container-' ~ c.name %}

{%-     for d in c.bind_dirs %}

{{ cprefix }}-bind-{{ d.path }}:
  file.directory:
    - name: {{ d.path }}
    - makedirs: True
{%-       if d.user is not none %}
    - user: {{ d.user }}
{%-       endif %}
{%-       if d.group is not none %}
    - group: {{ d.group }}
{%-       endif %}
{%-       if d.mode is not none %}
    - mode: '{{ d.mode }}'
{%-       endif %}
{%-     endfor %}

{{ cprefix }}-file:
  file.managed:
    - name: {{ c.file }}
    - source: salt://{{ tpldir }}/files/unit.jinja
    - template: jinja
    - user: root
    - group: root
    - mode: '0644'
    - context: {{ {'marker': q_marker, 'sections': c.sections} | json }}
    - require:
      - file: {{ prefix }}-dir
      - file: quadlet-network-file
{%-     if app.pod %}
      - file: {{ prefix }}-pod
{%-     endif %}
{%-     for v in c.volumes %}
      - file: {{ prefix }}-volume-{{ v.name }}
{%-     endfor %}
{%-     if quadlet.manage_services %}
    - onchanges_in:
      - cmd: quadlet-daemon-reload
{%-     endif %}

{%-     if quadlet.manage_services and c.pull %}

{{ cprefix }}-pull:
  cmd.run:
    - name: podman pull {{ c.image }}
    - unless: podman image exists {{ c.image }}
{%-       if quadlet.manage_package %}
    - require:
      - pkg: quadlet-package-installed
{%-       endif %}
{%-     endif %}
{%-   endfor %}

{%-   if quadlet.manage_services %}
{#-     Running: pod first, then its containers. Stopped: containers first. #}
{%-     if app.pod %}

{{ prefix }}-pod-service:
{%-       if app.running %}
  service.running:
{%-       else %}
  service.dead:
{%-       endif %}
    - name: {{ app.pod.service }}
    - require:
      - cmd: quadlet-daemon-reload
{%-       if app.running %}
      - service: quadlet-network-service
    {#- network changes reach the pod via Requires= on the network service #}
    - watch:
      - file: {{ prefix }}-pod
{%-       else %}
{%-         for c in app.containers %}
      - service: {{ prefix }}-container-{{ c.name }}-service
{%-         endfor %}
{%-       endif %}
{%-     endif %}

{%-     for c in app.containers %}
{%-       set cprefix = prefix ~ '-container-' ~ c.name %}

{{ cprefix }}-service:
{%-       if app.running %}
  service.running:
{%-       else %}
  service.dead:
{%-       endif %}
    - name: {{ c.service }}
    - require:
      - cmd: quadlet-daemon-reload
{%-       if app.running %}
      - service: quadlet-network-service
{%-         if app.pod %}
      - service: {{ prefix }}-pod-service
{%-         endif %}
{%-         if c.pull %}
      - cmd: {{ cprefix }}-pull
{%-         endif %}
{%-         for d in c.bind_dirs %}
      - file: {{ cprefix }}-bind-{{ d.path }}
{%-         endfor %}
    {#- a restarted pod takes its containers down with it (BindsTo=) #}
    - watch:
      - file: {{ cprefix }}-file
{%-         if app.pod %}
      - file: {{ prefix }}-pod
{%-         endif %}
{%-         for v in c.volumes %}
      - file: {{ prefix }}-volume-{{ v.name }}
{%-         endfor %}
{%-       endif %}
{%-     endfor %}
{%-   endif %}
{%- endfor %}
