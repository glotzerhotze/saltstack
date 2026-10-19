base:
  # Defaults for all minions
  '*':
    - local_grains
    - users
    - apt_keyrings
    - apt.repositories
    - apt.apt_conf
    - apt.preferences
    - apt.unattended
    - packages
    - quadlets
{%- if 'raspberry pi' not in grains.get('productname', '') | lower %}
    - packages.backports_kernel
{%- endif %}
    - nm_connections
    - restic.client

  'rpi-01':
    - restic.server
