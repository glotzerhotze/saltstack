# restic-formula

Salt formula for [restic](https://restic.net/) backups over SFTP, based on the
[restic example from the SaltStack book](https://thorstenkramm.gitbook.io/saltstack/beispiele/restic-backup)
and built to sit next to the
[users formula](https://github.com/saltstack-formulas/users-formula) and the
[openssh formula](https://github.com/saltstack-formulas/openssh-formula)
instead of duplicating what they already manage.

| Concern | Managed by |
|---|---|
| `restic` account, SSH key pair on clients, `authorized_keys` on the server | users formula (`users:restic`) |
| sshd on the backup server, optional `Match User restic` block, `known_hosts` | openssh formula |
| restic binary, capability, repository, password, schedule, scripts | this formula |

## States

| State | Use on | What it does |
|---|---|---|
| `restic` / `restic.client` | every host to back up | install restic, `setcap cap_dac_read_search`, `~/.ssh/config`, password, file lists, `restic init`, systemd timer (or cron) |
| `restic.server` | backup server | install restic (no capability), repository base dir, fuse for `restic mount` |
| `restic.install` | – | download, verify and install the binary (included by the above) |
| `restic.user` | – | requires the users formula, or creates the account when `restic:user:manage: true` |
| `restic.report` | clients | show the latest snapshots: `salt '*' state.apply restic.report` |
| `restic.monitoring` | clients (optional) | register a Better Stack heartbeat once per minion |

## Rollout

1. Create one key pair on the master and put it into pillar, see `pillar.example.sls`
   (`users:restic:ssh_keys` for clients, `users:restic:ssh_auth` for the server).
2. To keep generated repository passwords on the master, set in `/etc/salt/master`:
   ```yaml
   file_recv: True
   ```
3. Apply the server first, then the clients:
   ```sh
   salt backup.example.com state.apply users,openssh,restic.server
   salt '*' state.apply users,restic
   ```
4. Check: `salt '*' state.apply restic.report`

## What changed compared to the original example

The book lists a few problems and exercises; they are solved here:

- **Checksum:** the download is verified against the release's `SHA256SUMS`
  (`source_hash`). A tampered or wrong download fails and nothing is installed.
- **No repeated downloads:** the download only happens when `restic version`
  differs from `restic:version`, and the archive plus Salt's cached copy are
  removed afterwards. Changing `restic:version` upgrades or downgrades, and the
  file capability is re-applied to the new binary.
- **Distribute from the master:** put the `.bz2` under your file roots and set
  `restic:install:source: salt://restic/files/restic_0.19.1_linux_amd64.bz2`.
- **Paths from pillar:** `restic:client:paths` and `excludes` instead of a
  hard-coded list.
- **fuse on the server:** `restic.server` installs `fuse3` for `restic mount`.

Further changes:

- The private key comes from pillar via the users formula instead of
  `salt://restic/id_ed25519`, which every minion could download.
- The server key `restrict,command="internal-sftp"` makes the shared key
  usable for SFTP only (no shell, no tunnels).
- `StrictHostKeyChecking accept-new` instead of `no`, plus `BatchMode yes`
  so a missing key can never hang a Salt run on a password prompt.
- The binary is `root:restic 0750` as the restic docs recommend, so the
  capability-enabled binary is only usable by the restic user.
- The `getcap` check matches both the old (`+ep`) and new (`=ep`) output
  format; the original only knows `+ep`, so on current distributions
  `setcap` ran on every highstate.
- `restic cat config` instead of `restic stats` to detect an existing
  repository (`stats` walks the whole repository on every highstate).
- Daily systemd timer with randomized delay (instead of cron every 5
  minutes, which also pruned every 5 minutes), read-only system view for the
  job, a lock against overlapping runs, and `forget` limited to snapshots
  tagged `salt` and grouped by host.
- Storing the password on the backup server is optional and off by default.
- Monitoring works with any heartbeat URL (healthchecks.io, Better Stack, …),
  including a failure ping.

## Day-to-day

```sh
# on a client, as root
sudo -u restic /var/lib/restic/bin/restic-repo snapshots
sudo -u restic /var/lib/restic/bin/restic-repo restore latest --target /tmp/restore --include /etc/hosts

# run a backup now / see the last run
systemctl start restic-backup.service
journalctl -u restic-backup.service -n 50
```

**Restore after losing a machine:** the generated password is on the master at
`/var/cache/salt/master/minions/<id>/files/var/lib/restic/.restic-password`.
On the backup server:

```sh
su - restic
mkdir -p mnt/<id>
bin/restic -r repos/<id> -p /path/to/.restic-password mount mnt/<id>
```

When rebuilding a client with the same minion id, copy that file to
`/var/lib/restic/.restic-password` (owner `restic`, mode `0600`) **before**
the first highstate, otherwise a new password is generated that does not open
the existing repository.

**Switching to a pillar password** (`restic:client:password`) on an existing
repository: first add it as a key with `restic-repo key add`, otherwise the
repository can no longer be opened.

## Caveats

- All clients share one key and one server account, so a compromised client
  could delete other clients' repositories (it can't read them, they are
  encrypted per client). If that matters, use one key per client, or a
  [rest-server](https://github.com/restic/rest-server) with `--append-only`
  and `--private-repos` and set `restic:client:repository` to `rest:…`.
- Do not add `NoNewPrivileges=` (or options that imply it) to the systemd
  unit: it silently disables the file capability and the backup then can't read
  root-only files.
- `module.run` uses the new syntax (Salt 3005+).

## Tested

On Ubuntu 24.04 with Salt 3008.3, restic 0.19.1 and the current users formula:
server and client on one host via SFTP, repository init over the
`internal-sftp`-only key, backup of root-only files as the `restic` user, forget/prune,
`restic check`, idempotent re-runs, version change, rejected bad checksum,
heartbeat success and failure pings. The systemd units pass
`systemd-analyze verify`; the timer itself was not run (no systemd in the test container).

## Passwords

Create passwords with this command:
```shell
openssl rand -hex 20
```