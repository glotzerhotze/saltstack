# nm_connections – NetworkManager system connection profiles

Salt formula (MLM / Uyuni *Formula with Forms*) that manages system-wide
NetworkManager profiles as keyfiles in `/etc/NetworkManager/system-connections/`.

* one `<name>.nmconnection` per declared profile, `root:root 0600`
  (NetworkManager ignores keyfiles readable by others)
* any keyfile setting can be expressed – the formula does not hard-code
  connection types, so bonds, VLANs, bridges, 802.1X, InfiniBand, etc. all work
* `nmcli connection reload` only when a file actually changed
* optional per-profile activation, optional purge of undeclared profiles
* safe on transactional systems (SL Micro) and on hosts where NM is not running

## Layout

```
states/nm_connections/          -> /srv/salt/nm_connections/
  init.sls  map.jinja  defaults.yaml  files/connection.nmconnection.jinja
metadata/nm_connections/        -> /srv/formula_metadata/nm_connections/
  form.yml  metadata.yml
pillar.example
```

### Install on MLM 5.x (containerized server)

```bash
tar xzf nm_connections-formula.tar.gz
mgrctl cp nm_connections-formula/states/nm_connections   server:/srv/salt/
mgrctl cp nm_connections-formula/metadata/nm_connections server:/srv/formula_metadata/
```

The formula then shows up on the *Formulas* tab of systems and system groups.
Enable it, fill the form, save, apply highstate (or `nm_connections` alone).

### Plain Salt

Put `states/nm_connections` into a file root, write pillar like
`pillar.example`, and target `nm_connections` from `top.sls`.

## Pillar

| Key | Default | Meaning |
|---|---|---|
| `config_dir` | `/etc/NetworkManager/system-connections` | target directory (pillar only) |
| `reload` | `true` | `nmcli connection reload` after changes |
| `activate_timeout` | `60` | `nmcli --wait` for profiles with `activate: true` |
| `purge` | `false` | delete undeclared regular files in `config_dir` |
| `purge_keep` | `[]` | Python regexes on the file name that survive a purge |
| `connections` | `{}` | `<name>: {ensure, activate, settings}` |

Per profile:

* `ensure` – `present` (default) or `absent`
* `activate` – run `nmcli connection up` when the file changed (default `false`)
* `settings` – keyfile settings, flat `section.key: value` or nested
  `section: {key: value}`; mix freely. `connection.type` is required.
  YAML lists become `a;b;`, booleans `true`/`false`. Write values unescaped:
  backslashes and leading spaces are escaped for the keyfile format.

Section/key names are the *keyfile* names (`man nm-settings-keyfile`), not
always the nmcli property names – e.g. addresses are `ipv4.address1`,
`ipv4.address2`, … rather than `ipv4.addresses`. Quickest way to find the
right keys: build the profile once with `nmcli` and look at the file it writes.

## Behaviour worth knowing

**UUIDs.** Precedence: `connection.uuid` from pillar → the UUID already in the
file on disk → a stable UUIDv5 from minion id + profile name. Taking over an
existing profile under the same file name therefore keeps its UUID and does not
bounce the link. If you take over a profile stored under a *different* file
name, pin its current UUID (`nmcli -g connection.uuid c show <id>`) and remove
the old file, otherwise NM sees two profiles.

**Reload and activation.** NetworkManager does not watch the directory, so the
formula runs `nmcli connection reload` (once, if any profile changed). Changed
profiles are *not* re-applied to running devices unless `activate: true`;
otherwise they take effect on the next activation/reboot. Activating the
interface Salt itself talks over can cut the minion off if the profile is
wrong – keep `activate` off there and roll out in a maintenance window.

Both steps are skipped when NetworkManager is not active (e.g. SLES 15 with
wicked – files are staged for a later switch) and on transactional systems,
where the files land in the new snapshot and are used after the reboot.

**Purge.** Only regular files are considered; `.nmmeta` symlinks
(NetworkManager tombstones) are never touched. Deleting the file of an active
profile takes its device down after the reload. Run with `test=True` first.

**Secrets.** Values entered in the MLM form are stored as formula data and
visible to anyone who can edit the formula. For PSKs / 802.1X passwords prefer
a restricted pillar, or `*-flags=2` (agent-owned) where that fits.

**Form limitations.** The form only supports the flat `section.key` notation
and string values. Sections whose names contain dots (`[wireguard-peer.<key>]`)
need the nested pillar notation.
