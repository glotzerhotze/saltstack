# -*- coding: utf-8 -*-
# vim: ft=sls
#
# Full rollout: podman, the macvlan network, all apps from pillar, and
# removal of apps that were dropped from pillar or marked absent.
include:
  - .package
  - .config
  - .clean
  - .network
  - .apps
