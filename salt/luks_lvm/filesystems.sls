# -*- coding: utf-8 -*-
# vim: ft=sls
#
# Filesystems and mounts. mkfs only ever runs on a device with no signature
# at all, so existing data (any filesystem, partition table, ...) is left
# alone and simply mounted at the pillar's mountpoint.
{%- from tpldir ~ "/map.jinja" import luks_lvm with context %}

include:
  - .luks
  - .lvm

{%- set watch = [] %}
{%- for name, dev in luks_lvm.devices | dictsort if dev.crypttab %}
{%-   do watch.append(("file", "luks_lvm-" ~ name ~ "-crypttab")) %}
{%- endfor %}

{%- for m in luks_lvm.mounts %}
{%-   set device = m.device | quote %}

luks_lvm-mkfs-{{ m.id }}:
  cmd.run:
    - name: mkfs.{{ m.fs }} {{ m.mkfs_opts }} {{ device }}
    # Skip if anything is on the device. Also skip if it does not exist yet
    # (e.g. under test=True before unlocking); the mount then fails loudly.
    - unless: test ! -b {{ device }} || test -n "$(wipefs --noheadings {{ device }})"
    - require:
      - {{ m.req_mod }}: {{ m.req_id }}
      - pkg: luks_lvm-packages

{%-   if m.mountpoint %}
{%-     do watch.append(("mount", "luks_lvm-mount-" ~ m.id)) %}

luks_lvm-mount-{{ m.id }}:
  mount.mounted:
    - name: {{ m.mountpoint | json }}
    - device: {{ m.device | json }}
    - fstype: {{ m.fs }}
    - opts: {{ m.opts | json }}
    - mkmnt: True
    - persist: True
    - pass_num: {{ 2 if m.fs.startswith("ext") else 0 }}
{%-     if m.invisible_opts %}
    - extra_mount_invisible_options: {{ m.invisible_opts | json }}
{%-     endif %}
{%-     if m.invisible_keys %}
    - extra_mount_invisible_keys: {{ m.invisible_keys | json }}
{%-     endif %}
    - require:
      - cmd: luks_lvm-mkfs-{{ m.id }}
{%-     for p in m.parents %}
      - mount: luks_lvm-mount-{{ p }}
{%-     endfor %}
{%-   endif %}
{%- endfor %}

{%- if watch %}

# Let systemd regenerate its units from the changed crypttab/fstab, so the
# next boot (and `systemctl status`) agrees with what Salt just did.
luks_lvm-systemd-daemon-reload:
  cmd.run:
    - name: systemctl daemon-reload
    - onlyif: test -d /run/systemd/system
    - onchanges:
{%-   for mod, id in watch %}
      - {{ mod }}: {{ id }}
{%-   endfor %}
{%- endif %}
