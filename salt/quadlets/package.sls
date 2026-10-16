# -*- coding: utf-8 -*-
# vim: ft=sls
{%- from tpldir ~ '/map.jinja' import quadlet with context %}

{%- if quadlet.manage_package %}
quadlet-package-installed:
  pkg.installed:
    - name: {{ quadlet.pkg }}
{%- endif %}
