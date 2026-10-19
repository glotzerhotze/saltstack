# -*- coding: utf-8 -*-
# vim: ft=sls
#
# Show the latest snapshots of a client:
#   salt '*' state.apply restic.report
{%- set tplroot = tpldir.split('/')[0] %}
{%- from tplroot ~ "/map.jinja" import restic with context %}

restic-report:
  cmd.run:
    - name: '{{ restic.wrapper }} snapshots --compact --latest 5'
    - runas: {{ restic.user.name }}
    - cwd: {{ restic.user.home }}
