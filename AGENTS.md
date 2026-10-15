# AGENTS.md

Salt states, pillar, reactor and master config for a small home fleet (Debian
trixie hosts and Raspberry Pis). The master is the
[cdalvaro/docker-salt-master](https://github.com/cdalvaro/docker-salt-master)
container, running under Podman on `192.168.23.64` as the systemd unit
`salt-master`. Nothing in this repo runs locally. You edit files here, then
`scripts/deploy.sh` rsyncs them into the container's volumes.

## Layout and where it lands in the container

| Repo path   | Host volume (`/var/lib/containers/storage/volumes/…`) | Container path                  | Purpose |
|-------------|-------------------------------------------------------|---------------------------------|---------|
| `salt/`     | `salt-master-srv/_data/salt`                          | `/home/salt/data/srv/salt`      | State tree (`file_roots` base) |
| `pillar/`   | `salt-master-srv/_data/pillar`                        | `/home/salt/data/srv/pillar`    | Pillar tree (`pillar_roots` base) |
| `reactor/`  | `salt-master-srv/_data/reactor`                       | `/home/salt/data/srv/reactor`   | Reactor SLS, referenced by absolute path |
| `config/*`  | `salt-master-config/_data`                            | `/home/salt/data/config`        | Master `*.conf` drop-ins, auto-included |
| `3pfs/*`    | `salt-master-3pfs/_data`                              | `/home/salt/data/3pfs`          | Third-party formulas, git submodules |

Container conventions to follow:

- `SALT_BASE_DIR` defaults to `/home/salt/data/srv`, and the container expects
  `salt/` and `pillar/` directly under it. Keep that structure.
- Each subdirectory of `/home/salt/data/3pfs/` is added to `file_roots` **when
  the container starts**. So `3pfs/apt-formula/apt` is served as `salt://apt`.
  New formulas only show up after a restart or after running
  `entrypoint.sh app:reload-3rd-formulas` inside the container.
- Every `*.conf` file in `config/` is included by the master. Name new files
  with a numeric prefix (`NN-topic.conf`) so their load order stays explicit.
- Paths inside config and reactor files are **container** paths
  (`/home/salt/data/...`), never host or macOS paths.
- The salt-api user is `salt_api`. The container sets it up from
  `SALT_API_ENABLED` / `SALT_API_USER_PASS(_FILE)` on the host, not from this
  repo. Never put that password here.
- Keys (`/home/salt/data/keys`) and logs (`/home/salt/data/logs`) are not
  managed here.

## Directory guide

- `salt/top.sls`: the highstate. Every minion gets `local_grains`, `users`,
  `apt_keyrings`, `apt.*`, `packages` and `nm_connections`.
  `packages.backports_kernel` is skipped on Raspberry Pis (checked with
  `grains['productname']`).
- `salt/<formula>/`: in-house formulas.
  - `local_grains`: writes `pillar:local_grains` into grains, then refreshes
    grains.
  - `apt_keyrings`: downloads and verifies apt signing keys into
    `/etc/apt/keyrings`. The `files/keyring.sh` helper checks fingerprints and
    rejects weak SHA-1 bindings that Debian 13's sqv verifier refuses.
  - `nm_connections`: manages NetworkManager keyfiles. Its `README.md`
    documents the pillar schema.
  - `packages/backports_kernel.sls`: extends the upstream `packages` formula.
- `pillar/top.sls`: every minion gets `<formula>.common`, plus per-host files
  named `<formula>.<short_name>` and `<formula>.<minion_id with . → _>`. It uses
  `ignore_missing: True`, so a missing per-host file is fine. A **misnamed**
  file is silently ignored too, so double-check file names.
- `pillar/<formula>/`: one directory per formula, named after the formula's
  top-level pillar key.
- `reactor/local_grains.sls`: wired up in `config/10-reactor.conf`. It runs
  `state.apply local_grains` on a minion at `salt/minion/*/start` and on the
  custom event `custom/grains/sync`.
- `3pfs/`: upstream `saltstack-formulas` repos as git submodules. **Do not
  edit them.** Adjust behaviour through pillar, or add a wrapper state under
  `salt/`. `3pfs/salt-bootstrap` is excluded from deploy.
- `scripts/deploy.sh`: rsyncs everything above to the master and restarts it.

## Conventions

- Formulas follow the saltstack-formulas layout: `init.sls`, a `map.jinja`
  that merges `defaults.yaml` with pillar (`pillar.get(..., merge=True)`),
  plus `pillar.example`, `files/` and `README.md`.
- Validate pillar input in Jinja and fail loudly with
  `{{ raise('<formula>: …') }}`. Don't silently skip bad data.
- Use `tpldir` for paths that refer back to the formula itself, so it can be
  relocated.
- State IDs are prefixed with the formula name (`apt-keyring-<name>`,
  `nm_connection_<name>`). Keep requisites (`require`, `onchanges`) explicit.
- States must be idempotent. Use `unless`/`onlyif`/`onchanges` on `cmd.run`.
- Branch on hardware or OS with grains, as the existing files already do
  (`'raspberry pi' in grains.get('productname','') | lower`).
- Pillar SLS files may use Jinja. YAML anchors (`<<: *debian`) are used in
  `pillar/apt/common.sls`.
- Some existing comments are in German. Either language is fine; match the
  file you are editing.

## Secrets

`pillar/` holds real secrets: password hashes in `pillar/users/` and Wi-Fi
PSKs in `pillar/nm_connections/`. Do not print, log, copy or "example-ify"
their values. Don't add new plaintext secrets. Suggest GPG-encrypted pillar
(the container supports `keys/gpgkeys/`) or a restricted pillar instead.

## Validating changes

There is no local Salt or CI. Before suggesting a deploy:

1. Check that the YAML parses and the Jinja is balanced (read it carefully;
   `python -c 'import yaml'` only helps on files without Jinja).
2. After deploying, check on the master, as a dry run first:

   ```bash
   ssh root@192.168.23.64
   podman exec -it salt-master salt '<minion>' pillar.items          # pillar renders?
   podman exec -it salt-master salt '<minion>' state.show_sls <sls>  # states render?
   podman exec -it salt-master salt '<minion>' state.apply test=True # dry run
   ```

   (The container name may differ. Check with `podman ps`.)
3. For `nm_connections` changes, use `test=True` and leave `activate` off on
   the interface the minion uses to reach the master.

## Do not

- Run `scripts/deploy.sh`, `state.apply` without `test=True`, or anything that
  touches `192.168.23.64` or the minions unless the user explicitly asks. Both
  change live hosts.
- Edit or commit inside `3pfs/*` submodules.
- Hard-code host paths or minion IDs in states. Per-host data belongs in
  `pillar/<formula>/<host>.sls`.
- Commit `.DS_Store` or `.idea/`.
