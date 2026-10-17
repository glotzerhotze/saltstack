# -*- coding: utf-8 -*-
# vim: ft=sls
#
# Full rollout: podman, the macvlan network, all apps from pillar, and
# removal of apps that were dropped from pillar or marked absent.
# Minions without any `quadlets` pillar are left alone, so this can be
# targeted at '*'. (An empty `quadlets: {apps: {}}` still cleans up.)
{%- if salt['pillar.get']('quadlets') %}
include:
  - .package
  - .config
  - .clean
  - .network
  - .apps
{%- else %}
quadlets-no-pillar:
  test.nop:
    - name: no quadlets pillar for this minion, nothing to do
{%- endif %}
