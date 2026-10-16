# -*- coding: utf-8 -*-
# vim: ft=sls
#
# Quadlet directory and the single systemd daemon-reload that turns the unit
# files into services. Every unit file state adds itself to the reload with
# onchanges_in, so the reload runs once per highstate and only on changes.
{%- from tpldir ~ '/map.jinja' import quadlet with context %}

include:
  - .package

quadlet-config-dir:
  file.directory:
    - name: {{ quadlet.config_dir }}
    - user: root
    - group: root
    - mode: '0755'
    - makedirs: True

{%- if quadlet.manage_services %}

quadlet-daemon-reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: quadlet-config-dir
{%-   if quadlet.manage_package %}
    - require:
      - pkg: quadlet-package-installed
{%-   endif %}
{%- endif %}
