# Test pillar for the restic formula: client and server on one host (the
# two documents of salt/restic/pillar.example merged), plus restore and
# monitoring so restic.restore and restic.monitoring render their real
# states. All values are placeholders.

users:
  restic:
    fullname: Restic Backup
    home: /var/lib/restic
    system: true
    createhome: true
    shell: /bin/bash
    user_dir_mode: '0750'
    ssh_key_type: ed25519
    ssh_keys:
      privkey: placeholder-private-key
      pubkey: ssh-ed25519 AAAAplaceholder restic@salt-master
    ssh_auth:
      - 'restrict,command="internal-sftp" ssh-ed25519 AAAAplaceholder restic@salt-master'

restic:
  repo_base: /var/lib/restic/repos

  client:
    sftp:
      host: backup.example.com
    paths:
      - /etc
      - /root
      - /home
      - /var/lib/restic/data
    excludes:
      - /home/*/.cache
      - '*.tmp'
    pre_backup:
      - pg_dumpall > /var/lib/restic/data/postgres.sql
    heartbeat_url: https://hc-ping.example.com/00000000-0000-0000-0000-000000000000
    schedule:
      method: systemd
      on_calendar: '*-*-* 02:00:00'
      randomized_delay: 1h

  restore:
    snapshot: latest
    target: /var/tmp/restore
    include:
      - /etc/hosts
    dry_run: true
    args:
      - --overwrite
      - if-newer

  monitoring:
    betterstack:
      api_token: placeholder-token
