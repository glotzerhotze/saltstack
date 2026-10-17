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
{%- if 'raspberry pi' not in grains.get('productname', '') | lower %}
    - packages.backports_kernel
{%- endif %}
    - nm_connections

  # Podman quadlets (pillar: quadlets.<short_name>)
  'rpi-03 or rpi-03.*':
    - match: compound
    - quadlets
