# -*- coding: utf-8 -*-
# vim: ft=sls
{%- from tpldir ~ "/map.jinja" import luks_lvm with context %}

luks_lvm-packages:
  pkg.installed:
    - pkgs: {{ luks_lvm.pkgs | json }}
