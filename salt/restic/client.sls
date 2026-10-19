# -*- coding: utf-8 -*-
# vim: ft=sls
#
# Backup client: lets the restic user read every file (file capability),
# sets up the repository connection and password, initialises the repository
# and schedules the backup job.
#
# SSH key: deployed by the users formula (users:restic:ssh_keys), see
# pillar.example. The backup server must already accept that key before the
# repository can be initialised, so apply restic.server first.
{%- set tplroot = tpldir.split('/')[0] %}
{%- from tplroot ~ "/map.jinja" import restic with context %}
{%- set u = restic.user %}
{%- set c = restic.client %}
{%- set ctx = {'restic': restic} %}
{%- set is_sftp = restic.repository.startswith('sftp:') %}

include:
  - {{ tplroot }}.install

#
# Sanity check: the default repository needs to know the backup server
#
restic-client-settings:
{%- if is_sftp and restic.uses_default_sftp and not c.sftp.host %}
  test.fail_without_changes:
    - name: 'restic:client:sftp:host is not set in pillar'
{%- else %}
  test.succeed_without_changes:
    - name: 'repository {{ restic.repository }}'
{%- endif %}

#
# Allow restic to read all files without running as root
#
restic-setcap-pkg:
  pkg.installed:
    - name: {{ restic.pkgs.setcap }}

restic-setcap:
  cmd.run:
    - name: setcap cap_dac_read_search=+ep '{{ restic.bin }}'
    # getcap prints "cap_dac_read_search=ep" (new) or "= cap_dac_read_search+ep" (old)
    - unless: getcap '{{ restic.bin }}' | grep -Eq 'cap_dac_read_search(=|\+)ep'
    - require:
      - pkg: restic-setcap-pkg
      - file: restic-binary

#
# SSH client config for the sftp repository
#
{%- if is_sftp and c.sftp.manage_ssh_config and c.sftp.host %}
restic-ssh-dir:
  file.directory:
    - name: {{ u.home }}/.ssh
    - user: {{ u.name }}
    - group: {{ u.group }}
    - mode: '0700'
    - require:
      - sls: {{ tplroot }}.user

restic-ssh-config:
  file.managed:
    - name: {{ u.home }}/.ssh/config
    - source: salt://{{ tplroot }}/files/ssh_config.jinja
    - template: jinja
    - context: {{ ctx | json }}
    - user: {{ u.name }}
    - group: {{ u.group }}
    - mode: '0600'
    - require:
      - file: restic-ssh-dir
{%- endif %}

#
# Repository password
#
{%- if c.password %}
restic-password:
  file.managed:
    - name: {{ restic.password_file }}
    - contents_pillar: restic:client:password
    - user: root
    - group: {{ u.group }}
    - mode: '0640'
    - show_changes: false
    - require:
      - sls: {{ tplroot }}.user
{%- else %}
restic-password:
  cmd.run:
    - name: |
        set -e
        umask 077
        head -c 32 /dev/urandom | base64 | tr -d '\n' > '{{ restic.password_file }}.tmp'
        chown {{ u.name }}:{{ u.group }} '{{ restic.password_file }}.tmp'
        mv -f '{{ restic.password_file }}.tmp' '{{ restic.password_file }}'
    - creates: {{ restic.password_file }}
    - require:
      - sls: {{ tplroot }}.user

{%-   if c.push_password_to_master %}

# Keep a copy on the master in case the machine is lost.
# Needs `file_recv: True` in the master config.
restic-password-push:
  module.run:
    - cp.push:
      - path: {{ restic.password_file }}
    - onchanges:
      - cmd: restic-password
{%-   endif %}
{%- endif %}

#
# Environment, file lists and helper scripts
#
restic-env:
  file.managed:
    - name: {{ restic.env_file }}
    - source: salt://{{ tplroot }}/files/restic.env.jinja
    - template: jinja
    - context: {{ ctx | json }}
    - user: root
    - group: {{ u.group }}
    - mode: '0640'
    - show_changes: false
    - require:
      - sls: {{ tplroot }}.user

restic-files-from:
  file.managed:
    - name: {{ restic.files_from }}
    - contents: {{ (['# Managed by Salt (restic formula). One path or glob per line.'] + c.paths) | json }}
    - user: root
    - group: {{ u.group }}
    - mode: '0640'
    - require:
      - sls: {{ tplroot }}.user

restic-excludes:
  file.managed:
    - name: {{ restic.exclude_file }}
    - contents: {{ (['# Managed by Salt (restic formula). restic --exclude-file syntax.'] + c.excludes) | json }}
    - user: root
    - group: {{ u.group }}
    - mode: '0640'
    - require:
      - sls: {{ tplroot }}.user

# Drop zone for things that should end up in the backup (e.g. DB dumps)
restic-data-dir:
  file.directory:
    - name: {{ restic.data_dir }}
    - user: {{ u.name }}
    - group: {{ u.group }}
    - mode: '0700'
    - require:
      - sls: {{ tplroot }}.user

# restic with this host's repository settings:
#   sudo -u restic /var/lib/restic/bin/restic-repo snapshots
restic-wrapper:
  file.managed:
    - name: {{ restic.wrapper }}
    - source: salt://{{ tplroot }}/files/restic-repo.sh.jinja
    - template: jinja
    - context: {{ ctx | json }}
    - user: root
    - group: {{ u.group }}
    - mode: '0750'
    - require:
      - file: restic-bin-dir

{%- if c.heartbeat_url %}

restic-curl:
  pkg.installed:
    - name: curl
    - require_in:
      - file: restic-backup-script
{%- endif %}

restic-backup-script:
  file.managed:
    - name: {{ restic.backup_script }}
    - source: salt://{{ tplroot }}/files/run-backup.sh.jinja
    - template: jinja
    - context: {{ ctx | json }}
    - user: root
    - group: {{ u.group }}
    - mode: '0750'
    - require:
      - file: restic-bin-dir

#
# Initialise the repository once
#
restic-repo-init:
  cmd.run:
    - name: '{{ restic.wrapper }} init'
    - runas: {{ u.name }}
    - cwd: {{ u.home }}
    # `cat config` is cheap; the original `stats` walks the whole repository
    - unless: '{{ restic.wrapper }} cat config >/dev/null 2>&1'
    - require:
      - test: restic-client-settings
      - file: restic-binary
      - file: restic-env
      - file: restic-wrapper
      - {{ 'file' if c.password else 'cmd' }}: restic-password
{%- if is_sftp and c.sftp.manage_ssh_config and c.sftp.host %}
      - file: restic-ssh-config
{%- endif %}

{%- if c.store_password_on_server and is_sftp and restic.uses_default_sftp %}

# Optional and insecure: whoever can read the backup server can now also
# decrypt the backups.
restic-password-on-server:
  cmd.run:
    - name: "printf 'put %s %s/.restic-password\\n' '{{ restic.password_file }}' '{{ restic.sftp_path }}' | sftp -q -b - {{ c.sftp.alias }}"
    - unless: "printf 'ls %s/.restic-password\\n' '{{ restic.sftp_path }}' | sftp -q -b - {{ c.sftp.alias }} >/dev/null 2>&1"
    - runas: {{ u.name }}
    - cwd: {{ u.home }}
    - require:
      - cmd: restic-repo-init
{%- endif %}

#
# Schedule
#
{%- set method = c.schedule.method %}
{%- set unit_dir = '/etc/systemd/system' %}

{%- if method == 'systemd' %}

restic-backup-service-unit:
  file.managed:
    - name: {{ unit_dir }}/restic-backup.service
    - source: salt://{{ tplroot }}/files/restic-backup.service.jinja
    - template: jinja
    - context: {{ ctx | json }}
    - user: root
    - group: root
    - mode: '0644'

restic-backup-timer-unit:
  file.managed:
    - name: {{ unit_dir }}/restic-backup.timer
    - source: salt://{{ tplroot }}/files/restic-backup.timer.jinja
    - template: jinja
    - context: {{ ctx | json }}
    - user: root
    - group: root
    - mode: '0644'

restic-backup-timer:
  service.running:
    - name: restic-backup.timer
    - enable: true
    - require:
      - file: restic-backup-script
      - file: restic-files-from
      - file: restic-excludes
      - cmd: restic-setcap
    - watch:
      - file: restic-backup-service-unit
      - file: restic-backup-timer-unit

restic-backup-cron-absent:
  cron.absent:
    - name: {{ restic.backup_script }} > {{ u.home }}/last.log 2>&1
    - user: {{ u.name }}
    - identifier: RESTIC_BACKUP
    - onlyif: command -v crontab

{%- elif method == 'cron' %}

restic-cron-pkg:
  pkg.installed:
    - name: {{ restic.pkgs.cron }}

restic-cron-service:
  service.running:
    - name: {{ restic.cron_service }}
    - enable: true
    - require:
      - pkg: restic-cron-pkg

restic-backup-cron:
  cron.present:
    - name: {{ restic.backup_script }} > {{ u.home }}/last.log 2>&1
    - user: {{ u.name }}
    - identifier: RESTIC_BACKUP
    - minute: '{{ c.schedule.cron.minute }}'
    - hour: '{{ c.schedule.cron.hour }}'
    - require:
      - pkg: restic-cron-pkg
      - file: restic-backup-script
      - file: restic-files-from
      - file: restic-excludes
      - cmd: restic-setcap

restic-backup-timer-absent:
  service.dead:
    - name: restic-backup.timer
    - enable: false
    - onlyif: test -f {{ unit_dir }}/restic-backup.timer
  file.absent:
    - names:
      - {{ unit_dir }}/restic-backup.timer
      - {{ unit_dir }}/restic-backup.service
    - require:
      - service: restic-backup-timer-absent

{%- endif %}
