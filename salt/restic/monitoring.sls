# -*- coding: utf-8 -*-
# vim: ft=sls
#
# Registers a Better Stack heartbeat for this minion (once). The backup script
# picks up the heartbeat URL from <home>/monitoring-conf.json and pings it
# after every successful run. If restic:client:heartbeat_url is set in pillar,
# that URL wins and this state is not needed.
#
# Pillar: restic:monitoring:betterstack:api_token
{%- set tplroot = tpldir.split('/')[0] %}
{%- from tplroot ~ "/map.jinja" import restic with context %}
{%- set bs = restic.monitoring.betterstack %}
{%- set conf = restic.user.home ~ '/monitoring-conf.json' %}
{%- set payload = {'name': grains['id'] ~ ' restic backup', 'period': bs.period, 'grace': bs.grace} %}

include:
  - {{ tplroot }}.user

{%- if not bs.api_token %}

restic-monitoring:
  test.fail_without_changes:
    - name: 'restic:monitoring:betterstack:api_token is not set in pillar'

{%- else %}

restic-monitoring-pkgs:
  pkg.installed:
    - pkgs:
      - curl
      - jq

restic-monitoring:
  cmd.run:
    # The token is passed via the environment so it does not show up in the
    # state output or the process list.
    - name: >-
        curl -sSf --request POST
        --url '{{ bs.api_url }}'
        --header "Authorization: Bearer ${BETTERSTACK_TOKEN}"
        --header 'Content-Type: application/json'
        --data '{{ payload | json }}'
        -o '{{ conf }}.tmp'
        && mv -f '{{ conf }}.tmp' '{{ conf }}'
    - env:
      - BETTERSTACK_TOKEN: {{ bs.api_token | json }}
    - umask: '077'
    - runas: {{ restic.user.name }}
    - cwd: {{ restic.user.home }}
    - creates: {{ conf }}
    - require:
      - pkg: restic-monitoring-pkgs
      - sls: {{ tplroot }}.user

{%- endif %}
