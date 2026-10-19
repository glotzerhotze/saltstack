base:
  # Defaults for all minions
  '*':
    - local_grains
    - users
    - nm_connections
    - apt_keyrings
    - apt.repositories
    - apt.apt_conf
    - apt.preferences
    - apt.unattended
    - openssh.banner
    - openssh.config
    - openssh.client
    - packages
{%- if 'raspberry pi' not in grains.get('productname', '') | lower %}
    - packages.backports_kernel
{%- endif %}
    - quadlets
    - restic.client

  'rpi-01':
    - restic.server
