# -*- coding: utf-8 -*-
# vim: ft=sls
#
# Installs the restic release binary to <home>/bin/restic.
#
# Compared to a plain download this
#   - verifies the download against the release's SHA256SUMS (or your hash),
#   - downloads only when the installed version differs from `restic:version`,
#   - removes the archive (and Salt's cached copy) after installation.
#
# The binary is root:restic 0750, as recommended by the restic docs, so only
# the restic user can run it. That matters on clients, where it gets the
# cap_dac_read_search capability (see client.sls).
{%- set tplroot = tpldir.split('/')[0] %}
{%- from tplroot ~ "/map.jinja" import restic with context %}

include:
  - {{ tplroot }}.user

restic-bzip2:
  pkg.installed:
    - name: {{ restic.pkgs.bzip2 }}

restic-bin-dir:
  file.directory:
    - name: {{ restic.bin_dir }}
    - user: root
    - group: {{ restic.user.group }}
    - mode: '0750'
    - require:
      - sls: {{ tplroot }}.user

restic-download:
  file.managed:
    - name: {{ restic.archive }}
    - source: {{ restic.source }}
{%- if restic.source_hash %}
    - source_hash: {{ restic.source_hash }}
{%- endif %}
    - keep_source: false
    - user: root
    - group: root
    - mode: '0600'
    - makedirs: true
    - unless: {{ restic.version_check | json }}

restic-install:
  cmd.run:
    - name: |
        set -e
        bunzip2 -c '{{ restic.archive }}' > '{{ restic.bin }}.new'
        chown root:{{ restic.user.group }} '{{ restic.bin }}.new'
        chmod 0750 '{{ restic.bin }}.new'
        '{{ restic.bin }}.new' version
        mv -f '{{ restic.bin }}.new' '{{ restic.bin }}'
        rm -f '{{ restic.archive }}'
    - unless: {{ restic.version_check | json }}
    - require:
      - pkg: restic-bzip2
      - file: restic-bin-dir
      - file: restic-download

restic-binary:
  file.managed:
    - name: {{ restic.bin }}
    - replace: false
    - user: root
    - group: {{ restic.user.group }}
    - mode: '0750'
    - require:
      - cmd: restic-install
