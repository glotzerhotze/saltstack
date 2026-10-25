{#-
  nm_connections - manage system-wide NetworkManager connection profiles
  (keyfiles in /etc/NetworkManager/system-connections/<name>.nmconnection)
  and, optionally, /etc/NetworkManager/NetworkManager.conf.

  Pillar layout: see pillar.example. Every profile is described as keyfile
  settings, either flat ("ipv4.method: manual") or nested
  ("ipv4: {method: manual}"); both may be mixed. NetworkManager.conf is
  described nested only ("main: {plugins: [ifupdown, keyfile]}").
-#}
{%- from tpldir ~ "/map.jinja" import nm with context %}

{%- set config_dir   = nm.config_dir.rstrip('/') %}
{#- inner spaces allowed so installer files like "Wired connection 1" can be targeted -#}
{%- set name_re      = '^[A-Za-z0-9]([A-Za-z0-9 _.@+-]*[A-Za-z0-9_.@+-])?$' %}
{%- set section_re   = '^[^][\\s]+$' %}
{%- set key_re       = '^[^][\\s=#;]+$' %}
{#- Keyfile keys NetworkManager treats as secrets (psk, *password,
    password-raw, pin, private-key, preshared-key, mka-cak, wep-key0-3),
    plus everything in [vpn-secrets]. The *-flags keys are not secret. -#}
{%- set secret_key     = '(?:[^=\\s]*-)?(?:psk|password|password-raw|pin|private-key|preshared-key|mka-cak|wep-key[0-3])' %}
{%- set secret_key_re  = '^' ~ secret_key ~ '$' %}
{%- set secret_line_re = '^\\s*(?:' ~ secret_key ~ '\\s*=|\\[vpn-secrets\\])' %}
{%- set nm_is_active = 'systemctl is-active --quiet NetworkManager.service' %}
{#- On transactional systems (SL Micro) the files land in the new snapshot,
    so poking the running NetworkManager would only reload the old ones. -#}
{%- set runtime = (nm.reload | to_bool) and not grains.get('transactional', False) %}

{#- GKeyFile escaping: backslash -> \\, a leading space -> \s -#}
{%- macro esc(s) -%}
{%-   set s = s | string | replace('\\', '\\\\') -%}
{{-   '\\s' ~ s[1:] if s[:1] == ' ' else s -}}
{%- endmacro %}

{#- Render a pillar value the way NetworkManager's keyfile plugin expects -#}
{%- macro nmval(v) -%}
{%-   if v is sameas true or v is sameas false -%}{{ v | lower }}
{%-   elif v is string or v is number -%}{{ esc(v) }}
{%-   else -%}{% for i in v %}{{ esc(i) | replace(';', '\\;') }};{% endfor -%}
{%-   endif -%}
{%- endmacro %}

{#- Same for NetworkManager.conf, whose lists are separated by "," -#}
{%- macro confval(v) -%}
{%-   if v is sameas true or v is sameas false -%}{{ v | lower }}
{%-   elif v is string or v is number -%}{{ esc(v) }}
{%-   else -%}{% for i in v %}{{ esc(i) | replace(',', '\\,') }}{% if not loop.last %},{% endif %}{% endfor -%}
{%-   endif -%}
{%- endmacro %}

{#- NetworkManager.conf. Only managed when conf.settings has sections, so
    hosts without that pillar keep the file their package installed. #}
{%- set conf = nm.conf %}
{%- if conf is not mapping %}
{{ raise('nm_connections: "conf" must be a mapping {path, restart, settings}') }}
{%- endif %}
{%- set conf_settings = conf.get('settings') or {} %}
{%- if conf_settings is not mapping %}
{{ raise('nm_connections: conf.settings must be a mapping of <section>: {key: value}') }}
{%- endif %}

{%- if conf_settings %}
{%-   set conf_path = conf.get('path') %}
{%-   if conf_path is not string or not conf_path.startswith('/') %}
{{ raise('nm_connections: conf.path must be an absolute path, got "' ~ conf_path ~ '"') }}
{%-   endif %}

{%-   set conf_ordered = [] %}
{%-   for section in (conf_settings.keys() | select('equalto', 'main') | list) + (conf_settings.keys() | reject('equalto', 'main') | sort) %}
{%-     set options = conf_settings[section] or {} %}
{%-     if section is not match(section_re) %}
{{ raise('nm_connections: conf: invalid section name "' ~ section ~ '"') }}
{%-     elif options is not mapping %}
{{ raise('nm_connections: conf: section "' ~ section ~ '" must be a mapping of key: value') }}
{%-     endif %}
{%-     set opts = [] %}
{%-     for key, value in options | dictsort %}
{%-       if key is not match(key_re) %}
{{ raise('nm_connections: conf: invalid key "' ~ section ~ '.' ~ key ~ '"') }}
{%-       elif value is mapping %}
{{ raise('nm_connections: conf: value of "' ~ section ~ '.' ~ key ~ '" must be a scalar or a list') }}
{%-       elif value is not none and not (value is iterable and value is not string and value | length == 0) %}
{%-         set rendered = confval(value) | string %}
{%-         if '\n' in rendered or '\r' in rendered %}
{{ raise('nm_connections: conf: value of "' ~ section ~ '.' ~ key ~ '" contains a line break') }}
{%-         endif %}
{%-         do opts.append([key, rendered]) %}
{%-       endif %}
{%-     endfor %}
{%-     do conf_ordered.append([section, opts]) %}
{%-   endfor %}

nm_connections_conf:
  file.managed:
    - name: {{ conf_path | tojson }}
    - source: salt://{{ tpldir }}/files/NetworkManager.conf.jinja
    - template: jinja
    - user: root
    - group: root
    - mode: '0644'
    - makedirs: True
    - context:
        sections: {{ conf_ordered | tojson }}

{%-   if runtime %}

{#- Applied before the profiles below are reloaded. A reload does not pick
    up every setting, see conf.restart. #}
nm_connections_conf_apply:
  cmd.run:
{%-     if conf.get('restart', False) | to_bool %}
    - name: systemctl restart NetworkManager.service
{%-     else %}
    - name: nmcli general reload conf
{%-     endif %}
    - onlyif: {{ nm_is_active }}
    - onchanges:
      - file: nm_connections_conf
{%-   endif %}
{%- endif %}

{%- set declared    = [] %}  {#- paths owned by this formula (present + absent) #}
{%- set changed_ids = [] %}  {#- file states whose changes trigger a reload #}
{%- set activations = [] %}  {#- [cmd state id, file state id, uuid] #}

{%- if nm.connections is not mapping %}
{{ raise('nm_connections: "connections" must be a mapping of <name>: {...}') }}
{%- endif %}

{%- for name, conn in nm.connections | dictsort %}
{%-   set conn   = conn or {} %}
{%-   set ensure = conn.get('ensure') or 'present' %}
{%-   set path   = config_dir ~ '/' ~ name ~ '.nmconnection' %}
{%-   set sid    = 'nm_connection_' ~ name %}

{%-   if name is not match(name_re) %}
{{ raise('nm_connections: invalid connection name "' ~ name ~ '" (must match ' ~ name_re ~ ')') }}
{%-   endif %}
{%-   if ensure not in ['present', 'absent'] %}
{{ raise('nm_connections: ' ~ name ~ ': ensure must be "present" or "absent", got "' ~ ensure ~ '"') }}
{%-   endif %}
{%-   do declared.append(path) %}
{%-   do changed_ids.append(sid) %}

{%-   if ensure == 'absent' %}

{{ sid | tojson }}:
  file.absent:
    - name: {{ path | tojson }}

{%-   else %}

{#-   Normalise "section.key: value" and "section: {key: value}" into
      {section: {key: value}}. The split is on the first dot only, so
      [user] keys such as "user.org.example.tag" keep their dots. #}
{%-     set sections = {} %}
{%-     for prop, value in (conn.get('settings') or {}).items() %}
{%-       if value is mapping %}
{%-         for key, v in value.items() %}
{%-           do sections.setdefault(prop, {}).update({key: v}) %}
{%-         endfor %}
{%-       elif '.' in prop %}
{%-         set section, key = prop.split('.', 1) %}
{%-         do sections.setdefault(section, {}).update({key: value}) %}
{%-       else %}
{{ raise('nm_connections: ' ~ name ~ ': setting "' ~ prop ~ '" needs the form section.key, or a nested mapping') }}
{%-       endif %}
{%-     endfor %}

{%-     do sections.setdefault('connection', {}) %}
{%-     set c = sections['connection'] %}
{%-     if not c.get('type') %}
{{ raise('nm_connections: ' ~ name ~ ': connection.type is required (ethernet, bond, vlan, bridge, ...)') }}
{%-     endif %}
{%-     do c.setdefault('id', name) %}
{#-     UUID precedence: pillar > UUID already in the file on disk (so taking
        over an existing profile does not bounce the link) > stable UUIDv5
        derived from minion id + name. #}
{%-     if not c.get('uuid') %}
{%-       set on_disk = salt['ini.get_option'](path, 'connection', 'uuid') if salt['file.file_exists'](path) else None %}
{%-       do c.update({'uuid': on_disk or (grains['id'] ~ '/' ~ name) | uuid}) %}
{%-     endif %}

{%-     set ordered = [] %}
{%-     set secrets = [] %}
{%-     for section in ['connection'] + (sections.keys() | reject('equalto', 'connection') | sort) %}
{%-       if section is not match(section_re) %}
{{ raise('nm_connections: ' ~ name ~ ': invalid section name "' ~ section ~ '"') }}
{%-       endif %}
{%-       set opts = [] %}
{%-       for key, value in sections[section] | dictsort %}
{%-         if key is not match(key_re) %}
{{ raise('nm_connections: ' ~ name ~ ': invalid key "' ~ section ~ '.' ~ key ~ '"') }}
{%-         elif value is mapping %}
{{ raise('nm_connections: ' ~ name ~ ': value of "' ~ section ~ '.' ~ key ~ '" must be a scalar or a list') }}
{%-         elif value is not none and not (value is iterable and value is not string and value | length == 0) %}
{%-           set rendered = nmval(value) | string %}
{%-           if '\n' in rendered or '\r' in rendered %}
{{ raise('nm_connections: ' ~ name ~ ': value of "' ~ section ~ '.' ~ key ~ '" contains a line break') }}
{%-           endif %}
{%-           do opts.append([key, rendered]) %}
{%-           if section == 'vpn-secrets' or key is match(secret_key_re) %}
{%-             do secrets.append(section ~ '.' ~ key) %}
{%-           endif %}
{%-         endif %}
{%-       endfor %}
{%-       do ordered.append([section, opts]) %}
{%-     endfor %}
{#-     Hide the diff when the profile writes a secret, or when the file on
        disk still holds one (the diff would show it as a removed line). #}
{%-     set hide_diff = secrets or (salt['file.file_exists'](path) and salt['file.search'](path, secret_line_re)) %}

{{ sid | tojson }}:
  file.managed:
    - name: {{ path | tojson }}
    - source: salt://{{ tpldir }}/files/connection.nmconnection.jinja
    - template: jinja
    # NetworkManager ignores keyfiles not owned by root or readable by others
    - user: root
    - group: root
    - mode: '0600'
{%-     if hide_diff %}
    - show_changes: False
{%-     endif %}
    - makedirs: True
    - context:
        sections: {{ ordered | tojson }}

{%-     if conn.get('activate', False) | to_bool %}
{%-       do activations.append(['nm_connection_' ~ name ~ '_activate', sid, c['uuid']]) %}
{%-     endif %}
{%-   endif %}
{%- endfor %}

{#- Optional purge of profiles nobody declared. Only regular files are
    considered, so .nmmeta symlinks (NM tombstones) are never touched. #}
{%- if nm.purge | to_bool %}
{%-   for path in salt['file.find'](config_dir, type='f', maxdepth=1) | sort %}
{%-     set fname = path.split('/') | last %}
{%-     set kept = [] %}
{%-     for rgx in nm.purge_keep %}
{%-       if fname is match(rgx) %}{% do kept.append(rgx) %}{% endif %}
{%-     endfor %}
{%-     if path not in declared and not kept %}
{%-       set sid = 'nm_connection_purge_' ~ fname %}
{%-       do changed_ids.append(sid) %}

{{ sid | tojson }}:
  file.absent:
    - name: {{ path | tojson }}

{%-     endif %}
{%-   endfor %}
{%- endif %}

{%- if runtime and changed_ids %}

{#- NetworkManager does not watch the directory; it has to be told. #}
nm_connections_reload:
  cmd.run:
    - name: nmcli connection reload
    - onlyif: {{ nm_is_active }}
    - onchanges:
{%-   for sid in changed_ids %}
      - file: {{ sid | tojson }}
{%-   endfor %}

{%-   for cid, sid, cuuid in activations %}

{{ cid | tojson }}:
  cmd.run:
    - name: nmcli --wait {{ nm.activate_timeout | int }} connection up uuid {{ cuuid }}
    - onlyif: {{ nm_is_active }}
    - onchanges:
      - file: {{ sid | tojson }}
    - require:
      - cmd: nm_connections_reload
{%-   endfor %}
{%- endif %}

{%- if not changed_ids and not conf_settings %}

nm_connections_nothing_declared:
  test.nop
{%- endif %}
