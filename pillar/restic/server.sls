# -*- coding: utf-8 -*-
# vim: ft=yaml
#
# Example pillar for the restic formula, together with the users formula
# and the openssh formula (saltstack-formulas/users-formula and
# saltstack-formulas/openssh-formula).
#
# Generate one key pair for the backups on the master:
#   ssh-keygen -N "" -t ed25519 -C restic@salt-master -f /root/restic_id_ed25519
# and paste it below. Keeping the private key in pillar (instead of
# salt://restic/id_ed25519 as in the original example) means only the
# minions that are targeted with this pillar can read it.
#
# Suggested pillar top.sls:
#   base:
#     '*':                       # every host that is backed up
#       - restic.client
#     'backup.example.com':      # the backup server
#       - restic.server
#
# Suggested state top.sls:
#   base:
#     '*':
#       - users
#       - openssh
#       - restic                 # = restic.client
#     'backup.example.com':
#       - restic.server
#
# Order on first rollout: apply the server first, so it accepts the key
# before the clients try to initialise their repositories.
#
# The two YAML documents below go into two separate pillar files. A host that
# is both server and client gets both; Salt merges them.
---
########################################################################
# pillar/restic/server.sls  (backup server only)
########################################################################

users:
  restic:
    fullname: Restic Backup
    home: /var/lib/restic
    system: true
    createhome: true
    shell: /bin/bash
    user_dir_mode: '0750'
    ssh_auth_file:
      # `restrict,command="internal-sftp"` limits the key to SFTP: no shell,
      # no port forwarding, even though all clients share it.
      - ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC4Gk+zdKj3YE2BqQ3xe6VL/7WPZGjj0Qq7yNxlbK1Nrgfhr1600XlRMnXApeLri7Bs3IArOyV2X8RBCJ7TMoL9b/tYKT/3RAT23625urVz7UtayzcVzOjM9azEaKQVI57WRtJvOOEUzTI9pLef45gGrYQznJa95qY8/4aMSV3fbif/VkkeUKzc9DiQUOQj2T3/7FHorNsri6iNmBvTxraxUUwsiJc1r3clDNSpZiZZ2vwmqRigz/OJe+jmlULN2rKdrnsD7k7s6GDsL5BlEYviGqsdhqwfSTzJQkXQghzwlvtrpt8bSqUcrxGCjFfx/SSMybbE7mYqiDz6XpcexlLL tk@homebox.homework.lan  # noqa 204
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFoWv7STNMUVkQWz0Ns/Ixf2g3RIA5gZw426VAxmr+fr tk@homelab
      - 'restrict,command="internal-sftp" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKk7+PQ7Hv3Qd7wsMc90NQ+R/lzeLUAW9NNrGZSeO+VK restic-server@homelab'

# Optional, with the openssh formula: the same restriction for the whole
# account, on top of the key option above.
sshd_config:
  matches:
    restic_sftp_only:
      type:
        User: restic
      options:
        ForceCommand: internal-sftp
        AllowTcpForwarding: 'no'
        X11Forwarding: 'no'
        PasswordAuthentication: 'no'
  # If you use AllowUsers/AllowGroups, add `restic` there as well.

restic:
  repo_base: /var/lib/restic/repos
  server:
    packages: [fuse3]        # for `restic mount` on the server
