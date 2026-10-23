# -*- coding: utf-8 -*-
# vim: ft=sls
#
# LVM layer on top of the unlocked LUKS devices.
#   * an existing PV/VG/LV is used as-is
#   * an LV listed with size/extents is created if missing, and grown if the
#     pillar size is larger (shrinking is refused by lvm.lv_present)
#   * an LV listed without size/extents is only expected to exist (useful
#     for disks that were set up elsewhere and should just be mounted)
{%- from tpldir ~ "/map.jinja" import luks_lvm with context %}

include:
  - .luks

{%- for vgname, vg in luks_lvm.vgs | dictsort %}
{%-   for name in vg.devices %}
{%-     set mapper = luks_lvm.devices[name].mapper %}

# Salt's pvcreate passes --yes, which would wipe whatever is inside the
# unlocked container. Refuse unless it is empty or already an LVM PV.
luks_lvm-{{ name }}-refuse-non-pv:
  cmd.run:
    - name: >-
        echo "luks_lvm: refusing pvcreate on {{ mapper }}: it contains
        $(wipefs --noheadings --output TYPE {{ mapper }} | tr '\n' ' ')
        - fix the pillar (use 'mountpoint' instead of 'vg' for a plain filesystem)." >&2; exit 1
    - onlyif: wipefs --noheadings --output TYPE {{ mapper }} | grep -vqx LVM2_member
    - require:
      - cmd: luks_lvm-{{ name }}-open

luks_lvm-{{ name }}-pv:
  lvm.pv_present:
    - name: {{ mapper }}
    - unless: wipefs --noheadings --output TYPE {{ mapper }} | grep -vqx LVM2_member
    - require:
      - cmd: luks_lvm-{{ name }}-refuse-non-pv
{%-   endfor %}

luks_lvm-vg-{{ vgname }}:
  lvm.vg_present:
    - name: {{ vgname }}
    - devices:
{%-   for name in vg.devices %}
      - {{ luks_lvm.devices[name].mapper }}
{%-   endfor %}
    - require:
{%-   for name in vg.devices %}
      - lvm: luks_lvm-{{ name }}-pv
{%-   endfor %}

# udev normally auto-activates the VG once the PV appears, but that races
# with this run. Activate explicitly if any LV in the VG is inactive.
luks_lvm-vg-{{ vgname }}-activate:
  cmd.run:
    - name: vgchange --activate y {{ vgname }} && udevadm settle
    - unless: >-
        lvs --noheadings -o lv_attr {{ vgname }} |
        awk 'substr($1, 5, 1) != "a" { inactive = 1 } END { exit inactive }'
    - require:
      - lvm: luks_lvm-vg-{{ vgname }}

{#-   Fixed-size LVs first, percentage ones (e.g. 100%FREE) last, so a
      100%FREE LV does not take the space another LV still needs. #}
{%-   set fixed = vg.lvs | rejectattr("pct") | list %}
{%-   set pct = vg.lvs | selectattr("pct") | list %}
{%-   for lv in fixed + pct %}
{%-     if lv.creatable %}

{{ lv.id }}:
  lvm.lv_present:
    - name: {{ lv.name }}
    - vgname: {{ vgname }}
{%-       if lv.size %}
    - size: {{ lv.size | json }}
{%-       else %}
    - extents: {{ lv.extents | json }}
{%-       endif %}
    - resizefs: {{ lv.resizefs | json }}
    - require:
      - cmd: luks_lvm-vg-{{ vgname }}-activate
{%-       if lv.pct %}
{%-         for f in fixed if f.creatable %}
      - lvm: {{ f.id }}
{%-         endfor %}
{%-       endif %}
{%-     else %}

{{ lv.id }}:
  cmd.run:
    - name: >-
        echo "luks_lvm: LV {{ vgname }}/{{ lv.name }} does not exist and the pillar
        gives no size/extents to create it." >&2; exit 1
    - unless: lvs {{ vgname }}/{{ lv.name }}
    - require:
      - cmd: luks_lvm-vg-{{ vgname }}-activate
{%-     endif %}
{%-   endfor %}
{%- endfor %}
