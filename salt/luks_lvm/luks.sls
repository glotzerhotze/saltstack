# -*- coding: utf-8 -*-
# vim: ft=sls
#
# LUKS layer, per device:
#   * disk is already LUKS           -> never formatted, just unlocked
#   * disk is blank (no signatures)  -> luksFormat, then unlocked
#   * disk has any other signature   -> state fails, nothing is touched
#                                       (wipe it yourself if you mean it)
{%- from tpldir ~ "/map.jinja" import luks_lvm with context %}

include:
  - .packages

{%- if luks_lvm.devices.values() | selectattr("key_managed") | list %}

luks_lvm-keydir:
  file.directory:
    - name: {{ luks_lvm.keydir | json }}
    - user: root
    - group: root
    - mode: '0700'
{%- endif %}

{%- if luks_lvm.devices.values() | selectattr("crypttab") | list %}

# /etc/crypttab is edited line by line with core file states (the
# cryptdev.mapped state was dropped from Salt core in 3008). Only lines whose
# first field is one of our device names are touched; everything else in the
# file is left alone. This just makes sure the file exists.
luks_lvm-crypttab-file:
  file.managed:
    - name: /etc/crypttab
    - replace: False
    - user: root
    - group: root
{%- endif %}

{%- for name, dev in luks_lvm.devices | dictsort %}
{%-   set disk = dev.disk | quote %}
{%-   set keyfile = dev.keyfile | quote %}

luks_lvm-{{ name }}-disk-present:
  file.exists:
    - name: {{ dev.disk | json }}

{%-   if dev.key_managed %}

luks_lvm-{{ name }}-keyfile:
  file.managed:
    - name: {{ dev.keyfile | json }}
    # Read straight from pillar so the secret never appears in rendered SLS.
    - contents_pillar: luks_lvm:devices:{{ name }}:key
    # No trailing newline: the key file then equals the typed passphrase.
    - contents_newline: False
    - user: root
    - group: root
    - mode: '0400'
    - makedirs: True
    - dir_mode: '0700'
    - show_changes: False
    - require:
      - file: luks_lvm-keydir
{%-   else %}

luks_lvm-{{ name }}-keyfile:
  file.exists:
    - name: {{ dev.keyfile | json }}
{%-   endif %}

# Fails loudly if the disk holds something that is not LUKS (a filesystem,
# a partition table, an LVM PV, ...). Nothing gets formatted in that case.
luks_lvm-{{ name }}-refuse-foreign-data:
  cmd.run:
    - name: >-
        echo "luks_lvm: refusing to luksFormat {{ dev.disk }}: it is not LUKS but
        already contains: $(wipefs --noheadings --output TYPE {{ disk }} | tr '\n' ' ')
        - run 'wipefs -a {{ dev.disk }}' yourself if that data can go." >&2; exit 1
    - onlyif: >-
        ! cryptsetup isLuks {{ disk }} &&
        test -n "$(wipefs --noheadings {{ disk }})"
    - require:
      - file: luks_lvm-{{ name }}-disk-present
      - pkg: luks_lvm-packages

luks_lvm-{{ name }}-luks-format:
  cmd.run:
    - name: >-
        cryptsetup luksFormat --batch-mode {{ dev.luks_format_opts }}
        --key-file {{ keyfile }} {{ disk }}
    - unless: cryptsetup isLuks {{ disk }}
    # Second, independent guard: only ever format a disk with no signatures.
    - onlyif: test -z "$(wipefs --noheadings {{ disk }})"
    - require:
      - file: luks_lvm-{{ name }}-disk-present
      - file: luks_lvm-{{ name }}-keyfile
      - cmd: luks_lvm-{{ name }}-refuse-foreign-data

{%-   if dev.crypttab %}

{%-     set line = [name, dev.disk, dev.keyfile, dev.crypttab_opts] | join(" ") %}

luks_lvm-{{ name }}-crypttab:
  file.replace:
    - name: /etc/crypttab
    # Matches an existing entry for this name (not comments), replaces it
    # with the wanted line, or appends the line if there is none.
    - pattern: {{ ("^[ \\t]*" ~ (name | regex_escape) ~ "[ \\t].*$") | json }}
    - repl: {{ line | replace("\\", "\\\\") | json }}
    - append_if_not_found: True
    - backup: False
    - require:
      - file: luks_lvm-crypttab-file
      - cmd: luks_lvm-{{ name }}-luks-format
{%-   endif %}

luks_lvm-{{ name }}-open:
  cmd.run:
    - name: >-
        cryptsetup open --type luks --key-file {{ keyfile }} {{ dev.open_opts }}
        {{ disk }} {{ name }} && udevadm settle
    - unless: cryptsetup status {{ name }}
    - require:
      - cmd: luks_lvm-{{ name }}-luks-format
{%- endfor %}
