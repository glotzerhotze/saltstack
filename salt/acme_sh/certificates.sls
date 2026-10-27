{#- Issues, installs and removes the certificates declared in pillar under
    acme_sh:certificates by calling acme.sh directly.

    Per certificate, Salt renders into <state_dir>/<name>/:
      issue.conf    the --issue options (and a hash of env); when it changes,
                    a new certificate is requested
      install.conf  the --install-cert options; when it changes, the files
                    are copied again and reload_cmd runs
      pre-hook, post-hook, renew-hook, reload
                    the hook commands, handed to acme.sh as script paths so
                    they can change without a new certificate

    Whether acme.sh needs to run is read from acme.sh's own record of the
    certificate (Le_CertCreateTime, Le_InstallCertSuccessTime in
    <cert_home>/<domain>[_ecc]/<domain>.conf), compared with the time these
    files last changed. #}
{%- from tpldir ~ '/map.jinja' import acme_sh with context %}
{%- set header = acme_sh.header %}
{%- set script_head = [
      '#!/bin/sh',
      header,
      'set -e',
      'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
      'export PATH',
    ] %}
{#- succeeds if acme.sh recorded <field> at or after every file's mtime #}
{%- set newer_check = '[ -f "$1" ] && . "$1" && t=${%s:-0} && shift && for f; do [ "$t" -ge "$(stat -c %%Y "$f")" ] || exit 1; done' %}

include:
  - .install

{%- for name, overrides in acme_sh.certificates | dictsort %}
{%-   if not name is match('^[A-Za-z0-9][A-Za-z0-9._-]*$') %}
{{ raise('acme_sh: certificate name "' ~ name ~ '" may only contain letters, digits, ".", "_" and "-"') }}
{%-   endif %}
{%-   set cert = salt['slsutil.merge'](acme_sh.cert_defaults, overrides or {}) %}
{#-   env replaces the default env instead of merging with it, so one
      provider's credentials don't end up in another certificate's env #}
{%-   if overrides and 'env' in overrides %}
{%-     do cert.update({'env': overrides.env}) %}
{%-   endif %}
{%-   set sid = 'acme_sh_cert_' ~ name %}
{%-   set sdir = acme_sh.state_dir ~ '/' ~ name %}
{%-   set domains = cert.get('domains') or [name] %}
{%-   set main = domains[0] %}
{%-   set keylength = cert.keylength | string %}
{%-   set ecc = keylength.startswith('ec-') %}
{%-   set acme_dir = acme_sh.cert_home ~ '/' ~ main ~ ('_ecc' if ecc else '') %}
{%-   set acme_conf = acme_dir ~ '/' ~ main ~ '.conf' %}
{%-   set acme_files = {
        'key': acme_dir ~ '/' ~ main ~ '.key',
        'cert': acme_dir ~ '/' ~ main ~ '.cer',
        'ca': acme_dir ~ '/ca.cer',
        'fullchain': acme_dir ~ '/fullchain.cer',
      } %}
{%-   set cert_args = ['-d', main] + (['--ecc'] if ecc else []) %}

{#-   Destination files: names are relative to dest_dir, unless absolute #}
{%-   set dest_dir = cert.dest_dir or (acme_sh.dest_base ~ '/' ~ name) %}
{%-   set dest = {} %}
{%-   for kind in ['key', 'cert', 'ca', 'fullchain'] %}
{%-     set file = (cert.files or {}).get(kind) %}
{%-     if file %}
{%-       set path = file if file.startswith('/') else dest_dir ~ '/' ~ file %}
{%-       if path in dest.values() %}
{{ raise('acme_sh: certificate "' ~ name ~ '" uses ' ~ path ~ ' for more than one file') }}
{%-       endif %}
{%-       do dest.update({kind: path}) %}
{%-     endif %}
{%-   endfor %}
{%-   set uses_dest_dir = dest.values() | select('match', '^' ~ (dest_dir | regex_escape) ~ '/') | list | length > 0 %}

{%-   if cert.absent %}

{{ sid }}_remove:
  cmd.run:
    - name: {{ (acme_sh.command + ['--remove'] + cert_args) | map('quote') | join(' ') | tojson }}
    - onlyif: test -d {{ acme_dir | quote }}
    - require:
      - cmd: acme_sh_install

{{ sid }}_purge:
  file.absent:
    - names: {{ ([acme_dir, sdir] + (dest.values() | list) + ([dest_dir] if not cert.dest_dir else [])) | tojson }}
    - require:
      - cmd: {{ sid }}_remove

{%-   else %}

{#-   Hook scripts. All four are always passed to acme.sh, so adding or
      removing commands never requires a new certificate. #}
{%-   set scripts = {} %}
{%-   for kind, file in [('pre_hook', 'pre-hook'), ('post_hook', 'post-hook'),
                         ('renew_hook', 'renew-hook'), ('reload_cmd', 'reload')] %}
{%-     set value = cert.get(kind) %}
{%-     do scripts.update({file: [value] if value is string else (value or [])}) %}
{%-   endfor %}

{#-   acme.sh --issue options #}
{%-   set ch = cert.challenge or {} %}
{%-   set method = ch.get('method') %}
{%-   set issue = ['--server', cert.server | string, '--keylength', keylength] %}
{%-   for domain in domains %}
{%-     do issue.extend(['-d', domain]) %}
{%-   endfor %}
{%-   if method == 'dns' %}
{%-     if not ch.get('provider') %}
{{ raise('acme_sh: certificate "' ~ name ~ '" uses the dns challenge but sets no challenge:provider (e.g. dns_cf)') }}
{%-     endif %}
{%-     do issue.extend(['--dns', ch.provider]) %}
{%-     if ch.get('challenge_alias') %}{% do issue.extend(['--challenge-alias', ch.challenge_alias]) %}{% endif %}
{%-     if ch.get('domain_alias') %}{% do issue.extend(['--domain-alias', ch.domain_alias]) %}{% endif %}
{%-     if ch.get('dnssleep') is not none %}{% do issue.extend(['--dnssleep', ch.dnssleep | string]) %}{% endif %}
{%-   elif method == 'webroot' %}
{%-     if not ch.get('webroot') %}
{{ raise('acme_sh: certificate "' ~ name ~ '" uses the webroot challenge but sets no challenge:webroot') }}
{%-     endif %}
{%-     do issue.extend(['--webroot', ch.webroot]) %}
{%-   elif method == 'standalone' %}
{%-     do issue.append('--standalone') %}
{%-     if ch.get('httpport') %}{% do issue.extend(['--httpport', ch.httpport | string]) %}{% endif %}
{%-   elif method == 'alpn' %}
{%-     do issue.append('--alpn') %}
{%-     if ch.get('tlsport') %}{% do issue.extend(['--tlsport', ch.tlsport | string]) %}{% endif %}
{%-   elif method in ['nginx', 'apache'] %}
{%-     do issue.append('--' ~ method) %}
{%-   else %}
{{ raise('acme_sh: certificate "' ~ name ~ '" needs challenge:method (dns, webroot, standalone, alpn, nginx or apache)') }}
{%-   endif %}
{%-   do issue.extend([
        '--pre-hook', sdir ~ '/pre-hook',
        '--post-hook', sdir ~ '/post-hook',
        '--renew-hook', sdir ~ '/renew-hook',
      ]) %}
{%-   if cert.days %}{% do issue.extend(['--days', cert.days | string]) %}{% endif %}
{%-   if cert.profile %}{% do issue.extend(['--cert-profile', cert.profile]) %}{% endif %}
{%-   if cert.preferred_chain %}{% do issue.extend(['--preferred-chain', cert.preferred_chain]) %}{% endif %}
{%-   for arg in cert.extra_args or [] %}
{%-     do issue.append(arg | string) %}
{%-   endfor %}

{#-   options that copy the certificate out after issue and every renewal #}
{%-   set install = [] %}
{%-   for kind in ['key', 'cert', 'ca', 'fullchain'] if kind in dest %}
{%-     do install.extend(['--' ~ kind ~ '-file', dest[kind]]) %}
{%-   endfor %}
{%-   do install.extend(['--reloadcmd', sdir ~ '/reload']) %}

{%-   set env = {} %}
{%-   for key, value in (cert.env or {}) | dictsort %}
{%-     do env.update({key: value | string}) %}
{%-   endfor %}
{%-   set env_hash = salt['hashutil.sha256_digest'](env | dictsort | tojson) %}

{%-   set managed = [] %}

{%-   for file, commands in scripts | dictsort %}
{%-     do managed.append(sid ~ '_' ~ file) %}

{{ sid }}_{{ file }}:
  file.managed:
    - name: {{ (sdir ~ '/' ~ file) | tojson }}
    - mode: '0700'
    - makedirs: True
    - dir_mode: '0700'
    - contents: {{ (script_head + commands) | tojson }}
    - require:
      - file: acme_sh_state_dir
{%-   endfor %}
{%-   do managed.extend([sid ~ '_issue.conf', sid ~ '_install.conf']) %}

{{ sid }}_issue.conf:
  file.managed:
    - name: {{ (sdir ~ '/issue.conf') | tojson }}
    - mode: '0600'
    - makedirs: True
    - dir_mode: '0700'
    - contents: {{ ([
        header,
        '# acme.sh --issue options. A new certificate is requested when this',
        '# file changes (that includes the env hash, i.e. new credentials).',
      ] + issue + ['# env: sha256 ' ~ env_hash]) | tojson }}
    - require:
      - file: acme_sh_state_dir

{{ sid }}_install.conf:
  file.managed:
    - name: {{ (sdir ~ '/install.conf') | tojson }}
    - mode: '0600'
    - makedirs: True
    - dir_mode: '0700'
    - contents: {{ ([
        header,
        '# acme.sh --install-cert options. The files are copied again and',
        '# reload runs when this file or the reload script changes.',
      ] + install) | tojson }}
    - require:
      - file: acme_sh_state_dir

{#-   removes anything else, e.g. files from earlier versions of the formula #}
{{ sid }}_dir:
  file.directory:
    - name: {{ sdir | tojson }}
    - mode: '0700'
    - clean: True
    - require:
{%-   for id in managed %}
      - file: {{ id }}
{%-   endfor %}

{%-   if uses_dest_dir %}

{{ sid }}_dest_dir:
  file.directory:
    - name: {{ dest_dir | tojson }}
    - user: {{ cert.user | tojson }}
    - group: {{ cert.group | tojson }}
    - mode: {{ cert.dir_mode | string | tojson }}
    - makedirs: True
{%-   endif %}

{%-   if dest %}

{#-   Owner and mode of the copied files. Missing files are created empty, so
      acme.sh writes into a file that already has the right permissions (it
      keeps them on every renewal); existing content is never touched. #}
{{ sid }}_dest_files:
  file.managed:
    - names:
{%-     for kind, path in dest | dictsort %}
      - {{ path | tojson }}:
        - mode: {{ (cert.key_mode if kind == 'key' else cert.cert_mode) | string | tojson }}
{%-     endfor %}
    - user: {{ cert.user | tojson }}
    - group: {{ cert.group | tojson }}
    - replace: False
    - makedirs: True
{%-     if uses_dest_dir %}
    - require:
      - file: {{ sid }}_dest_dir
{%-     endif %}
{%-   endif %}

{#-   Request a certificate when there is none yet, or issue.conf changed
      since the last one was issued. The install options go along, so the
      first issue runs pre-hook, copy, reload, post-hook just like a renewal. #}
{{ sid }}_issue:
  cmd.run:
    - name: {{ (acme_sh.command + ['--issue'] + issue + install + ['--force']) | map('quote') | join(' ') | tojson }}
{%-   if env %}
    - env: {{ env | tojson }}
{%-   endif %}
    - unless:
      - test -s {{ acme_files.fullchain | quote }}
      - sh -c {{ (newer_check | format('Le_CertCreateTime')) | quote }} _ {{ acme_conf | quote }} {{ (sdir ~ '/issue.conf') | quote }}
    - require:
      - cmd: acme_sh_install
      - file: {{ sid }}_dir
{%-   if dest %}
      - file: {{ sid }}_dest_files
{%-   endif %}

{#-   Copy the files again and run reload when install.conf or the reload
      script changed, a copy is missing or differs from acme.sh's, or the last
      install failed (e.g. reload_cmd returned an error). #}
{{ sid }}_install:
  cmd.run:
    - name: {{ (acme_sh.command + ['--install-cert'] + cert_args + install) | map('quote') | join(' ') | tojson }}
    - unless:
      - sh -c {{ (newer_check | format('Le_InstallCertSuccessTime')) | quote }} _ {{ acme_conf | quote }} {{ (sdir ~ '/install.conf') | quote }} {{ (sdir ~ '/reload') | quote }}
      - sh -c '[ -f "$1" ] && . "$1" && [ "${Le_InstallCertSuccessTime:-0}" -ge "${Le_CertCreateTime:-0}" ]' _ {{ acme_conf | quote }}
{%-   for kind, path in dest | dictsort %}
      - cmp -s {{ acme_files[kind] | quote }} {{ path | quote }}
{%-   endfor %}
    - require:
      - cmd: {{ sid }}_issue
{%-   endif %}
{%- endfor %}
