{#-
  nm_connections - manage system-wide NetworkManager connection profiles
  (keyfiles in /etc/NetworkManager/system-connections/<name>.nmconnection).

  Pillar layout: see pillar.example. Every profile is described as keyfile
  settings, either flat ("ipv4.method: manual") or nested
  ("ipv4: {method: manual}"); both may be mixed.
-#}
{%- from tpldir ~ "/map.jinja" import nm with context %}

{%- set config_dir   = nm.config_dir.rstrip('/') %}
{#- inner spaces allowed so installer files like "Wired connection 1" can be targeted -#}
{%- set name_re      = '^[A-Za-z0-9]([A-Za-z0-9 _.@+-]*[A-Za-z0-9_.@+-])?$' %}
{%- set section_re   = '^[^][\\s]+$' %}
{%- set key_re       = '^[^][\\s=#;]+$' %}
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
{%-         endif %}
{%-       endfor %}
{%-       do ordered.append([section, opts]) %}
{%-     endfor %}

{{ sid | tojson }}:
  file.managed:
    - name: {{ path | tojson }}
    - source: salt://{{ tpldir }}/files/connection.nmconnection.jinja
    - template: jinja
    # NetworkManager ignores keyfiles not owned by root or readable by others
    - user: root
    - group: root
    - mode: '0600'
    - show_changes: False
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

{%- if not changed_ids %}

nm_connections_nothing_declared:
  test.nop
{%- endif %}
