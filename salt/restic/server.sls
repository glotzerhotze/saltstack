# -*- coding: utf-8 -*-
# vim: ft=sls
#
# Backup server: plain SFTP over the system's sshd.
#
#   - sshd itself is managed by the openssh formula (nothing here touches it)
#   - the restic account and its authorized_keys come from the users formula
#   - this file adds the repository directory, fuse for `restic mount`
#     and the restic binary for restores/checks on the server
{%- set tplroot = tpldir.split('/')[0] %}
{%- from tplroot ~ "/map.jinja" import restic with context %}
{%- set u = restic.user %}

include:
  - {{ tplroot }}.install

restic-repo-base:
  file.directory:
    - name: {{ restic.repo_base }}
    - user: {{ u.name }}
    - group: {{ u.group }}
    - mode: '0700'
    - makedirs: true
    - require:
      - sls: {{ tplroot }}.user

{%- if restic.server.packages %}

restic-server-packages:
  pkg.installed:
    - pkgs: {{ restic.server.packages | json }}
{%- endif %}

{#- Only for the standalone mode (restic:user:manage: true).
    With the users formula use users:restic:ssh_auth instead. #}
{%- for key in restic.server.authorized_keys %}

restic-authorized-key-{{ loop.index }}:
  ssh_auth.present:
    - name: {{ key | json }}
    - user: {{ u.name }}
    - require:
      - sls: {{ tplroot }}.user
{%- endfor %}
