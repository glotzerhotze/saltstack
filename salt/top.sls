base:
  # Defaults for all minions
  '*':
    - luks_lvm
    - local_grains
    - locale
    - write_environment
    - acme_sh
    - users
    - nm_connections
    - apt.repositories
    - apt.apt_conf
    - apt.preferences
    - apt.unattended
    - apt.update
    - apt.upgrade
    - openssh
    - openssh.config
    - openssh.client
    - openssh.banner
    - packages
{%- if 'raspberry pi' not in grains.get('productname', '') | lower %}
    - packages.backports_kernel
{%- endif %}
    - quadlets
    - restic.client

  'server-01':
    - restic.server
    - samba
