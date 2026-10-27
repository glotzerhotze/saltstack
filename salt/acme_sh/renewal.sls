{#- Schedules `acme.sh --cron`, which renews every certificate acme.sh knows
    about once it is due, via a systemd timer or a cron job. #}
{%- from tpldir ~ '/map.jinja' import acme_sh with context %}
{%- set method = acme_sh.renewal.method %}
{%- set renew = (acme_sh.command + ['--cron']) | map('quote') | join(' ') %}
{%- set unit = '/etc/systemd/system/acme-sh-renew' %}

{%- if method not in ['systemd', 'cron', 'none'] %}
{{ raise('acme_sh: renewal:method must be systemd, cron or none, not "' ~ method ~ '"') }}
{%- endif %}

include:
  - .install

{%- if method == 'systemd' %}
{#- No Persistent=true: it makes the timer require the mount units for
    /var/lib/systemd/timers, and it then fails to start where one of them
    (e.g. var.mount) is masked. OnBootSec makes up for missed runs. #}
{%-   set timer = [
        acme_sh.header,
        '[Unit]',
        'Description=Daily renewal of certificates managed by acme.sh',
        '',
        '[Timer]',
        'OnCalendar=' ~ acme_sh.renewal.on_calendar,
      ] %}
{%-   if acme_sh.renewal.on_boot %}
{%-     do timer.append('OnBootSec=' ~ acme_sh.renewal.on_boot) %}
{%-   endif %}
{%-   do timer.extend([
        'RandomizedDelaySec=' ~ acme_sh.renewal.randomized_delay,
        '',
        '[Install]',
        'WantedBy=timers.target',
      ]) %}

acme_sh_renew_units:
  file.managed:
    - mode: '0644'
    - names:
      - {{ (unit ~ '.service') | tojson }}:
        - contents: {{ [
            acme_sh.header,
            '[Unit]',
            'Description=Renew certificates managed by acme.sh',
            'Wants=network-online.target',
            'After=network-online.target',
            '',
            '[Service]',
            'Type=oneshot',
            'ExecStart=' ~ renew,
          ] | tojson }}
      - {{ (unit ~ '.timer') | tojson }}:
        - contents: {{ timer | tojson }}

acme_sh_renew_daemon_reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: acme_sh_renew_units

acme_sh_renew_timer:
  service.running:
    - name: acme-sh-renew.timer
    - enable: True
    - require:
      - cmd: acme_sh_install
      - cmd: acme_sh_renew_daemon_reload
    - watch:
      - file: acme_sh_renew_units

{%- else %}

acme_sh_renew_timer_stopped:
  service.dead:
    - name: acme-sh-renew.timer
    - enable: False
    - onlyif: test -f {{ unit }}.timer

acme_sh_renew_units_absent:
  file.absent:
    - names:
      - {{ unit }}.service
      - {{ unit }}.timer
    - require:
      - service: acme_sh_renew_timer_stopped

acme_sh_renew_daemon_reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onchanges:
      - file: acme_sh_renew_units_absent
{%- endif %}

{%- if method == 'cron' %}

acme_sh_cron_package:
  pkg.installed:
    - name: {{ acme_sh.cron_package | tojson }}
    - reload_modules: True

acme_sh_renew_cron:
  cron.present:
    - name: {{ (renew ~ ' >/dev/null') | tojson }}
    - identifier: acme_sh_renew
    - user: root
    - minute: random
    - hour: random
    - require:
      - pkg: acme_sh_cron_package
      - cmd: acme_sh_install

{%- elif salt['cmd.has_exec']('crontab') %}

acme_sh_renew_cron:
  cron.absent:
    - name: {{ (renew ~ ' >/dev/null') | tojson }}
    - identifier: acme_sh_renew
    - user: root
{%- endif %}
