# -*- coding: utf-8 -*-
# vim: ft=sls
#
# Downloads every key in pillar apt_keyrings:keys into /etc/apt/keyrings.
#
#   dearmor: true  (default) -> <name>.gpg, binary keyring; the URL may serve
#                               an armored or a binary key
#   dearmor: false           -> <name>.asc, stored verbatim
#   fingerprint: [...]       -> pinned: checked on EVERY run, the keyring is
#                               only written if the download contains exactly
#                               these primary keys
#   source_hash: sha256=...  -> pinned by file hash instead of / as well
#   allow_weak_digests: true -> skip the check that rejects keys bound only by
#                               SHA-1/SHA-224 signatures (which apt's sqv
#                               verifier on Debian 13+ refuses)
#
# Without source_hash the URL is re-checked every run via HTTP ETag, so a key
# rotated upstream is picked up (and, if pinned, rejected until the pillar
# fingerprint is updated).
#
# Depend on one key with "- require: - cmd: apt-keyring-<name>",
# or on all of them with "- require: - sls: apt_keyrings".

{%- from "apt_keyrings/map.jinja" import apt_keyrings as kr with context %}
{%- set cache = opts.cachedir ~ '/apt_keyrings' %}
{%- set tool = '/bin/sh ' ~ cache ~ '/keyring.sh' %}

apt-keyrings-gpg:
  pkg.installed:
    - name: {{ kr.gpg_pkg }}

apt-keyrings-directory:
  file.directory:
    - name: {{ kr.directory }}
    - user: root
    - group: root
    - mode: '0755'
    - makedirs: True

apt-keyrings-cache:
  file.directory:
    - name: {{ cache }}
    - user: root
    - group: root
    - mode: '0700'
    - makedirs: True

apt-keyrings-tool:
  file.managed:
    - name: {{ cache }}/keyring.sh
    - source: salt://apt_keyrings/files/keyring.sh
    - user: root
    - group: root
    - mode: '0700'
    - require:
      - file: apt-keyrings-cache

{%- for name, cfg in kr.get('keys', {}) | dictsort %}
{#-   Shorthand: "docker: https://..." is the same as "docker: {url: https://...}" #}
{%-   set k = {'url': cfg} if cfg is string else cfg %}
{%-   set dearmor = k.get('dearmor', kr.dearmor) %}
{%-   set filename = k.get('filename', name ~ ('' if dearmor else '.asc')) %}
{%-   set fprs = k.get('fingerprint', []) %}
{%-   set fprs = [fprs] if fprs is string else fprs %}
{%-   set fprs = fprs | join(',') | replace(' ', '') or '-' %}
{%-   set digests = 'allow-weak' if k.get('allow_weak_digests', kr.allow_weak_digests) else 'strict' %}

{#-   Names end up in paths and shell commands: keep them boring. #}
{%-   if not k.get('url') %}
{{      raise('apt_keyrings: key "' ~ name ~ '" has no url') }}
{%-   endif %}
{%-   for n in [name, filename] %}
{%-     if not n | regex_match('^([A-Za-z0-9][A-Za-z0-9._-]*)$') %}
{{        raise('apt_keyrings: invalid key name or filename "' ~ n ~ '"') }}
{%-     endif %}
{%-   endfor %}
{%-   if not fprs | regex_match('^([0-9A-Fa-f,]+|-)$') %}
{{      raise('apt_keyrings: key "' ~ name ~ '": fingerprint must be hex') }}
{%-   endif %}
{%-   if dearmor and filename.endswith('.asc') %}
{{      raise('apt_keyrings: key "' ~ name ~ '" is dearmored, so its filename must not end in .asc') }}
{%-   endif %}

{%-   set src = cache ~ '/' ~ name %}
{%-   set args = [name, 'binary' if dearmor else 'verbatim', fprs, digests, src,
                  kr.directory ~ '/' ~ filename] | join("' '") %}

apt-keyring-{{ name }}-download:
  file.managed:
    - name: {{ src }}
    - source: {{ k.url }}
{%-   if k.get('source_hash') %}
    - source_hash: {{ k.source_hash }}
{%-   else %}
    # NOT skip_verify: with skip_verify Salt never re-downloads a cached URL
    - use_etag: True
{%-   endif %}
    - user: root
    - group: root
    - mode: '0600'
    - require:
      - file: apt-keyrings-cache

apt-keyring-{{ name }}:
  cmd.run:
    - name: {{ tool }} install '{{ args }}'
    - unless: {{ tool }} uptodate '{{ args }}'
    - require:
      - pkg: apt-keyrings-gpg
      - file: apt-keyrings-directory
      - file: apt-keyrings-tool
      - file: apt-keyring-{{ name }}-download
{%- endfor %}

{# Add packages containing keyrings  #}
install_keyring_packages:
  pkg.latest:
  - pkgs:
{% set packages = salt['pillar.get']('apt_keyrings:packages') %}
{% for package in packages %}
    - {{ package }}
{% endfor %}