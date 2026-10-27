# -*- coding: utf-8 -*-
# vim: ft=sls
#
# Restores a snapshot of this host's repository. Not part of the highstate:
# apply it on purpose and pass the details as command-line pillar, e.g.
#   salt <minion> state.apply restic.restore pillar='{"restic": {"restore": {"target": "/var/tmp/restore"}}}'
#
# Runs as root, so files can be written anywhere and get their owners back.
# Restoring the same snapshot twice gives the same result, but this is an
# action rather than a desired state, so there is no unless/onlyif guard
# (like restic.report). Needs restic 0.17 or newer.
{%- set tplroot = tpldir.split('/')[0] %}
{%- from tplroot ~ "/map.jinja" import restic with context %}
{%- set r = restic.restore %}
{%- set snapshot = r.snapshot | string %}

{%- if r.target is not string or not r.target.startswith('/') %}
{{ raise('restic: restic:restore:target must be an absolute path (a staging directory, or / to restore in place), got "' ~ r.target ~ '"') }}
{%- endif %}
{%- if not snapshot or snapshot.startswith('-') %}
{{ raise('restic: restic:restore:snapshot must be a snapshot ID, "latest" or "<snapshot>:<subfolder>", got "' ~ snapshot ~ '"') }}
{%- endif %}
{%- for opt in ['include', 'exclude', 'args'] %}
{%-   if r[opt] is string or r[opt] is mapping or r[opt] is not iterable %}
{{ raise('restic: restic:restore:' ~ opt ~ ' must be a list') }}
{%-   endif %}
{%- endfor %}

{%- set cmd = [restic.wrapper, 'restore', snapshot, '--target', r.target] %}
{%- for pattern in r.include %}
{%-   do cmd.append('--include=' ~ pattern) %}
{%- endfor %}
{%- for pattern in r.exclude %}
{%-   do cmd.append('--exclude=' ~ pattern) %}
{%- endfor %}
{%- if r.dry_run | to_bool %}
{%-   do cmd.extend(['--dry-run', '-vv']) %}
{%- endif %}
{%- for arg in r.args %}
{%-   do cmd.append(arg | string) %}
{%- endfor %}

include:
  - {{ tplroot }}.client

restic-restore:
  cmd.run:
    - name: {{ cmd | map('quote') | join(' ') | json }}
    - cwd: /
    - require:
      - cmd: restic-repo-init
