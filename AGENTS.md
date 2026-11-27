# AGENTS.md

Salt states, pillar, reactor and master config for a small home fleet (Debian
trixie hosts and Raspberry Pis). The master is a SaltGUI build of
[cdalvaro/docker-salt-master](https://github.com/cdalvaro/docker-salt-master),
running under Podman on rpi-01 (`192.168.23.65`) as the container
`salt-master-app` in the pod `salt-master` (systemd unit `salt-master-pod`),
with haproxy in front of SaltGUI. The pod is itself a quadlet from
`pillar/quadlets/rpi-01.sls`. Nothing in this repo is applied locally
(`scripts/test.sh` only renders). You edit files here, then
`scripts/deploy.sh` rsyncs them into the container's volumes.

## Layout and where it lands in the container

| Repo path   | Host volume (`/var/lib/containers/storage/volumes/…`) | Container path                  | Purpose |
|-------------|-------------------------------------------------------|---------------------------------|---------|
| `salt/`     | `salt-master-srv/_data/salt`                          | `/home/salt/data/srv/salt`      | State tree (`file_roots` base) |
| `pillar/`   | `salt-master-srv/_data/pillar`                        | `/home/salt/data/srv/pillar`    | Pillar tree (`pillar_roots` base) |
| `reactor/`  | `salt-master-srv/_data/reactor`                       | `/home/salt/data/srv/reactor`   | Reactor SLS, referenced by absolute path |
| `modules/`  | `salt-master-srv/_data/modules`                       | `/home/salt/data/srv/modules`   | Master-side custom modules (`module_dirs`) |
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
- The salt-api user is `saltgui`, which SaltGUI logs in with. It is set as
  `SALT_API_USER` in `pillar/quadlets/rpi-01.sls` and must match
  `external_auth` in `config/20-salt-api.conf`. The password comes from
  1Password and reaches the container as the podman secret `salt-api-pass`.
  Never put the password itself here.
- Keys (`/home/salt/data/keys`) and logs (`/home/salt/data/logs`) are not
  managed here.

## Directory guide

- `salt/top.sls`: the highstate. Every minion gets `local_grains`, `users`,
  `apt.*`, `packages` and `nm_connections`.
  `packages.backports_kernel` is skipped on Raspberry Pis (checked with
  `grains['productname']`).
- `salt/<formula>/`: in-house formulas.
  - `local_grains`: writes `pillar:local_grains` into grains, then refreshes
    grains.
  - `nm_connections`: manages NetworkManager keyfiles. Its `README.md`
    documents the pillar schema.
  - `packages/backports_kernel.sls`: extends the upstream `packages` formula.
- `pillar/top.sls`: every minion gets `<formula>.common`, plus per-host files
  named `<formula>.<short_name>` and `<formula>.<minion_id with . → _>`. It uses
  `ignore_missing: True`, so a missing per-host file is fine. A **misnamed**
  file is silently ignored too, so double-check file names.
- `pillar/<formula>/`: one directory per formula, named after the formula's
  top-level pillar key.
- `pillar/apt/common.sls`: pillar for the greenaar apt formula in
  `3pfs/apt-formula`. Third-party signing keys are set per repository with
  `key_url`. Keep the `signed-by` file name ending in `.asc`, so Salt stores
  the armored key without needing `gpg`.
- `pillar/ipam.yaml`: every fleet IP and MAC address (subnets, gateways,
  host interfaces, macvlan shims, container IPs and MACs, DNS servers).
  Pillar files look addresses up with the macros in `pillar/ipam.jinja`
  (`ip`, `ips`, `cidr`, `mac`) instead of hard-coding them. A lookup that
  misses fails the pillar render.
  Neither file is in `top.sls`; they are only imported.
- `reactor/local_grains.sls`: wired up in `config/10-reactor.conf`. It runs
  `state.apply local_grains` on a minion at `salt/minion/*/start` and on the
  custom event `custom/grains/sync`.
- `modules/modules/`: custom execution modules that run on the **master**.
  `config/50-modules.conf` points `module_dirs` at `/home/salt/data/srv/modules`,
  and Salt looks for a `modules/` subdirectory inside it, which is why the
  path is doubled. Currently this holds `onepassword.py` (see Secrets).
  Changes take effect after a master restart. These modules are not synced
  to minions; minion-side modules would go in `salt/_modules/`.
- `config/`: master drop-ins.
  - `10-reactor.conf`: reactor wiring.
  - `20-salt-api.conf`: PAM `external_auth` for `saltgui`,
    `netapi_enable_clients`, and salt-api on `127.0.0.1:8000` behind the
    pod's haproxy.
  - `30-gitfs.conf`: gitfs, currently disabled.
  - `40-onepassword.conf`: settings for the `onepassword` module.
  - `50-modules.conf`: `module_dirs`.
  - `onepassword.token`: the 1Password service account token. It is
    gitignored, but **it is deployed** with `config/*`.
- `3pfs/`: upstream `saltstack-formulas` repos as git submodules. **Do not
  edit them.** Adjust behaviour through pillar, or add a wrapper state under
  `salt/`. `3pfs/salt-bootstrap` is excluded from deploy.
- `scripts/deploy.sh`: rsyncs everything above to the master with
  `--delete`, then restarts it. The local tree is the source of truth: a file
  deleted here also disappears on the master.
- `scripts/test.sh [-s suite] [-j jobs] [sls ...]`: renders SLS locally with
  `salt-call --local state.show_sls` (every SLS under `salt/` by default),
  with `salt/` and `3pfs/*` as file_roots. Pillar comes from
  `test/pillar/<suite>/`, grains from `test/grains/<suite>.yaml` (falls
  back to `default.yaml`). The rendered states land in `test/out/<suite>/`
  (gitignored). Needs a local `salt-call` (`/opt/salt/salt-call` here).
- `test/pillar/default/`: test pillar. Several files are symlinks to the
  formula's `pillar.example`, so editing an example changes the test. Use
  placeholders only: test pillar never calls `onepassword.*`. Its `top.sls`
  has no `ignore_missing`, so a misnamed file fails the run. A new formula
  needs an entry there, or its states render with defaults only.
- `renovate.json`, `.github/workflows/renovate.yml`: Renovate runs weekly on
  GitHub and opens pull requests for newer image tags in
  `pillar/quadlets/*.sls`. Every `{%- set <name>_version = '<tag>' %}` there
  needs a `{#- renovate: depName=<image> #}` comment directly above it, so add
  one for each new image. Merging such a PR deploys nothing.

## Conventions

- Formulas follow the saltstack-formulas layout: `init.sls`, a `map.jinja`
  that merges `defaults.yaml` with pillar (`pillar.get(..., merge=True)`),
  plus `pillar.example.sls`, `files/` and `README.md`.
- Validate pillar input in Jinja and fail loudly with
  `{{ raise('<formula>: …') }}`. Don't silently skip bad data.
- Use `tpldir` for paths that refer back to the formula itself, so it can be
  relocated.
- State IDs are prefixed with the formula name (`restic-download`,
  `nm_connection_<name>`). Keep requisites (`require`, `onchanges`) explicit.
- States must be idempotent. Use `unless`/`onlyif`/`onchanges` on `cmd.run`.
- Branch on hardware or OS with grains, as the existing files already do
  (`'raspberry pi' in grains.get('productname','') | lower`).
- Pillar SLS files may use Jinja. YAML anchors (`<<: *debian`) are used in
  `pillar/apt/common.sls`.
- Some existing comments are in German. Either language is fine; match the
  file you are editing.

## Secrets

Secrets come from **1Password** and are read on the master while pillar is
rendered. They are never written into this repo:

```jinja
wifi-security.psk: {{ salt['onepassword.read']('op://infra/<item>/<field>') | yaml_dquote }}   # keep quoted
```

- Always pipe the value through `yaml_dquote`. Otherwise a value containing
  `: `, ` #`, `yes` or leading zeros breaks the YAML or changes its type.
- Also available: `onepassword.get(vault, item, field='password',
  section=None)` and `onepassword.item(vault, item)`. The full docs are in
  the module docstring.
- Only the master needs the `op` CLI (`/usr/bin/op` inside the container)
  and the token. Minions only receive the resolved values in their own
  pillar. Never call `onepassword.*` from states under `salt/`.
- The service account is rate limited, and pillar renders for every minion
  on every refresh. References by ID (`op://<vault-id>/<item-id>/...`) cost
  1 read; references by name cost 3. The module caches values for
  `cache_ttl` (300 s), so a rotated secret reaches minions within 5 minutes,
  or right away after a master restart.
- States that write secrets to files set `show_changes: False`, as
  `nm_connections` does, so values don't leak into diffs and job returns. Do
  the same in any new state that handles secrets.

Rules:

- Never write a secret value into a file in this repo, and never print one.
  When a profile or config needs one, add a 1Password reference. If you
  don't know the `op://` path, ask the user instead of leaving the field
  empty: an empty PSK would wipe the working key on the host.
- The user password hash in `pillar/users/` comes from 1Password
  (`op://infra/tk-user/password-hash`). It is still a secret: don't print it,
  and avoid `pillar.items` on minions, which shows it.
- Never read, print or modify `config/onepassword.token`.
- To check a secret on the master, prefer `salt-run salt.cmd
  onepassword.version` or `onepassword.ratelimit`. Only use
  `salt-run salt.cmd onepassword.read` when the user asks, because it prints
  the secret.

## Validating changes

There is no CI. Before suggesting a deploy:

1. Run `scripts/test.sh` (or `scripts/test.sh <sls> ...` for the formulas
   you touched). It must exit 0. It only covers `salt/` with test pillar:
   it does not render the real `pillar/` tree (that needs 1Password on the
   master) or `top.sls`, so also check that the YAML in `pillar/` parses
   and its Jinja is balanced.
2. After deploying, check on the master, as a dry run first:

   ```bash
   ssh root@192.168.23.65
   podman exec -it salt-master-app salt '<minion>' pillar.items          # pillar renders?
   podman exec -it salt-master-app salt '<minion>' state.show_sls <sls>  # states render?
   podman exec -it salt-master-app salt '<minion>' state.apply test=True # dry run
   ```

   (The container name may differ. Check with `podman ps`.)

   After changing `modules/` or `config/40-onepassword.conf`, check that the
   module loads and can authenticate before rendering any pillar:
   `podman exec -it salt-master-app salt-run salt.cmd onepassword.version`.
3. For `nm_connections` changes, use `test=True` and leave `activate` off on
   the interface the minion uses to reach the master.

## Do not

- Run `scripts/deploy.sh`, `state.apply` without `test=True`, or anything that
  touches `192.168.23.65` or the minions unless the user explicitly asks. Both
  change live hosts.
- Edit or commit inside `3pfs/*` submodules.
- Hard-code host paths or minion IDs in states. Per-host data belongs in
  `pillar/<formula>/<host>.sls`.
- Commit `.DS_Store` or `.idea/`.
- Commit `config/onepassword.token` or any secret value. `pillar/` is
  committed, so secrets in it must stay 1Password references.
