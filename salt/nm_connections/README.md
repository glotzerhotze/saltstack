# nm_connections

Manages NetworkManager on the minions from pillar:

- connection profiles, as keyfiles in
  `/etc/NetworkManager/system-connections/<name>.nmconnection`
- optionally NetworkManager's own configuration,
  `/etc/NetworkManager/NetworkManager.conf`

The formula does not know about connection types or config options. Whatever
you put under `settings` is written to the file, so bonds, VLANs, bridges,
macvlan, Wi-Fi, WireGuard and any NetworkManager.conf option all work the same
way.

`salt/top.sls` applies `nm_connections` to every minion. A host without
`nm_connections` pillar is left alone: no file is written or removed.

## Files

| File | Purpose |
|---|---|
| `init.sls` | validates pillar and builds all states |
| `map.jinja` | merges `defaults.yaml` with the `nm_connections` pillar |
| `defaults.yaml` | defaults for every option |
| `files/connection.nmconnection.jinja` | template for a connection profile |
| `files/NetworkManager.conf.jinja` | template for NetworkManager.conf |
| `pillar.example.sls` | commented example of every option |

## What a run does

1. `map.jinja` deep-merges the pillar on top of `defaults.yaml`.
2. **NetworkManager.conf**, only when `conf:settings` has at least one
   section: the sections are validated and written to `conf:path`
   (`root:root 0644`). If the file changed, NetworkManager is told with
   `nmcli general reload conf`, or restarted when `conf:restart` is true.
3. **Connection profiles**: every entry under `connections` is validated,
   normalised into keyfile sections and written as `<name>.nmconnection`
   (`root:root 0600`, without diffs in the output). `ensure: absent` removes
   the file instead.
4. **Purge** (off by default): regular files in `config_dir` that are not
   declared and don't match `purge_keep` are removed.
5. If any profile file changed, `nmcli connection reload` runs once. Then
   `nmcli connection up` runs for each changed profile with `activate: true`.
6. When nothing is declared at all, a single `test.nop` keeps the state
   from failing.

The calls in steps 2 and 5 that talk to the running NetworkManager are
skipped when NetworkManager is not active, when `reload` is false, and on
transactional systems (grain `transactional`). The files are still written
and are used the next time NetworkManager starts.

Bad pillar data stops the render with an error that starts with
`nm_connections:`. Nothing is silently skipped.

## Pillar

`pillar/top.sls` loads `pillar/nm_connections/<short name>.sls`, e.g.
`pillar/nm_connections/rpi-01.sls`. There is no `nm_connections.common` in
`pillar/top.sls` yet. To give every host the same NetworkManager.conf, add
`- nm_connections.common` there before the per-host line and put the
`conf:` block into `pillar/nm_connections/common.sls`. Pillar files are merged
deeply, so a host file can then override single keys. Lists are replaced, not
merged.

All keys live under `nm_connections:`. See `pillar.example.sls` for a full
example.

| Key | Default | Meaning |
|---|---|---|
| `config_dir` | `/etc/NetworkManager/system-connections` | where the profiles are written |
| `reload` | `true` | tell the running NetworkManager about changed files |
| `activate_timeout` | `60` | `nmcli --wait` for profiles with `activate: true` |
| `purge` | `false` | remove undeclared regular files from `config_dir` |
| `purge_keep` | `[]` | Python regexes on the file name that survive a purge |
| `connections` | `{}` | `<name>: {ensure, activate, settings}` |
| `conf:path` | `/etc/NetworkManager/NetworkManager.conf` | the config file to manage |
| `conf:restart` | `false` | restart NetworkManager after a config change instead of reloading it |
| `conf:settings` | `{}` | `<section>: {key: value}`; empty means the file is not managed |

### Connection profiles

```yaml
nm_connections:
  connections:
    mgmt:                      # file name: mgmt.nmconnection
      ensure: present          # or absent
      activate: false          # nmcli connection up after a change
      settings:
        connection.type: ethernet
        connection.interface-name: eth0
        ipv4.method: manual
        ipv4.address1: 10.10.0.21/24
        ipv4.dns: [10.10.0.53, 10.10.1.53]
        ipv6: {method: disabled}
```

- The profile name is the file name. It may contain letters, digits,
  `_ . @ + -` and inner spaces (so `Wired connection 1` from the installer
  can be removed).
- `settings` takes keyfile settings, flat (`section.key: value`) or nested
  (`section: {key: value}`), mixed as you like. The flat form splits on the
  first dot only. Sections with a dot in their name
  (`wireguard-peer.<key>`) need the nested form.
- `connection.type` is required. `connection.id` defaults to the profile name.
- YAML lists become `a;b;`, booleans `true`/`false`. Write values
  unescaped; backslashes, a leading space and `;` inside list items are
  escaped for you. A key set to `null` or `[]` is left out.
- The names are the **keyfile** names (`man nm-settings-keyfile`), which are
  not always the nmcli property names: addresses are `ipv4.address1`,
  `ipv4.address2`, … rather than `ipv4.addresses`. The quickest way to find
  the right keys is to create the profile once with `nmcli` and look at the
  file it writes.

### NetworkManager.conf

```yaml
nm_connections:
  conf:
    restart: false
    settings:
      main:
        no-auto-default: '*'
        plugins: [ifupdown, keyfile]
      ifupdown:
        managed: false
      logging:                 # written as an empty [logging] section
```

- Only the nested form, `section: {key: value}`. Section and key names are
  the ones from `man NetworkManager.conf`, written as they appear in the file
  (`[device]` key `wifi.backend`, `[connection]` key `ipv6.ip6-privacy`).
- `[main]` comes first, the other sections and all keys are sorted, so the
  file only changes when the pillar does.
- YAML lists become `a,b`, booleans `true`/`false`. A key set to `null` or
  `[]` is left out, which is also how a host file removes a key that
  `common.sls` sets. A section without keys is written as an empty
  `[section]`.
- Quote values YAML would otherwise change: `'*'` (an alias to YAML),
  `'no'`, `'yes'`, `'on'`, `'off'` (booleans), and numbers with leading
  zeros.
- The whole file is replaced, so anything not in pillar is gone afterwards,
  including the comments the package shipped.
- To leave the packaged file alone and only add settings, point `conf:path`
  at a drop-in such as `/etc/NetworkManager/conf.d/90-salt.conf`.
  NetworkManager reads those after the main file.

## Behaviour worth knowing

**UUIDs.** A profile's UUID is, in this order: `connection.uuid` from pillar,
the UUID already in the file on disk, or a stable UUIDv5 made from minion id
and profile name. Taking over an existing profile under the same file name
therefore keeps its UUID and does not bounce the link. If you take over a
profile stored under a *different* file name, pin its current UUID
(`nmcli -g connection.uuid connection show <id>`) and remove the old file,
otherwise NetworkManager sees two profiles.

**Profile changes and running devices.** NetworkManager does not watch
`config_dir`, which is why the formula runs `nmcli connection reload`. A
reloaded profile is *not* re-applied to a device that is already up, unless
the profile has `activate: true`. Otherwise it takes effect on the next
activation or reboot. Re-activating the interface the minion uses to reach
the master cuts the minion off if the profile is wrong, so keep `activate`
off there.

**Config changes need a restart for some settings.** `nmcli general reload
conf` re-reads NetworkManager.conf and `conf.d/`, but not every setting can
change at runtime. `[main] plugins` and `[ifupdown] managed`, for example, are
only read at startup. Either set `conf:restart: true`, or reboot after the
change. A NetworkManager restart normally leaves configured devices up, but a
changed `plugins` or `managed` can change which devices NetworkManager
manages. Try a restart on a host you can reach some other way first.

**Purge.** Only regular files are considered, so `.nmmeta` symlinks
(NetworkManager's tombstones) are never touched. Deleting the file of an
active profile takes its device down after the reload. Run with `test=True`
first.

**Secrets.** PSKs and 802.1X passwords come from 1Password, read on the
master while pillar is rendered. Always quote them with `yaml_dquote`:

```jinja
wifi-security.psk: {{ salt['onepassword.read']('op://infra/<item>/<field>') | yaml_dquote }}
```

Profiles are written with `show_changes: False`, so secret values don't show
up in diffs or job returns. NetworkManager.conf shows its diff, so don't put
secrets there.

## Testing a change

Nothing in this repo runs locally. After `scripts/deploy.sh`, on the master:

```bash
podman exec -it salt-master salt '<minion>' pillar.get nm_connections
podman exec -it salt-master salt '<minion>' state.show_sls nm_connections
podman exec -it salt-master salt '<minion>' state.apply nm_connections test=True
```

`test=True` shows which files would change and which `nmcli` or
`systemctl` commands would run. The diff of NetworkManager.conf is shown;
the diffs of profiles are not.
