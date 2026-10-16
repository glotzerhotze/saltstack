# -*- coding: utf-8 -*-
# vim: ft=sls
#
# Full rollout: podman, the macvlan network, all quadlets from pillar, and
# removal of quadlets that were dropped from pillar or marked absent.
include:
  - .package
  - .config
  - .clean
  - .network
  - .containers
