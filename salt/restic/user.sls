# -*- coding: utf-8 -*-
# vim: ft=sls
#
# The restic account.
#
# Default: the account (and its SSH keys) come from the users formula, so this
# file only includes that formula and gives other restic states something to
# require. Set `restic:user:manage: true` to create a minimal account here.
{%- set tplroot = tpldir.split('/')[0] %}
{%- from tplroot ~ "/map.jinja" import restic with context %}
{%- set u = restic.user %}

{%- if u.manage %}

restic-user:
  group.present:
    - name: {{ u.group }}
    - system: true
  user.present:
    - name: {{ u.name }}
    - fullname: Restic Backup
    - home: {{ u.home }}
    - createhome: true
    - shell: {{ u.shell }}
    - system: true
    - gid: {{ u.group }}
    - require:
      - group: restic-user

restic-user-home:
  file.directory:
    - name: {{ u.home }}
    - user: {{ u.name }}
    - group: {{ u.group }}
    - mode: '0750'
    - require:
      - user: restic-user

restic-user-ssh-dir:
  file.directory:
    - name: {{ u.home }}/.ssh
    - user: {{ u.name }}
    - group: {{ u.group }}
    - mode: '0700'
    - require:
      - file: restic-user-home

{%- else %}

{%-   if u.require_sls %}
include:
  - {{ u.require_sls }}
{%-   endif %}

# Placeholder so `require: sls: restic.user` works in both modes.
restic-user:
  test.nop:
    - name: restic account is managed by {{ u.require_sls or 'something else' }}
{%-   if u.require_sls %}
    - require:
      - sls: {{ u.require_sls }}
{%-   endif %}

{%- endif %}
