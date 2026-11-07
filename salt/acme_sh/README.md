# acme_sh Salt formula

Issues TLS certificates with [acme.sh](https://github.com/acmesh-official/acme.sh)
from pillar data: you declare which certificates should exist, where their
files go and which commands run around issuing; the formula calls acme.sh to
make it so, and acme.sh's own `--cron` keeps them renewed.

## Layout

```
acme_sh/
  init.sls            install + certificates + renewal
  install.sls         acme.sh from git (acme.sh --install)
  certificates.sls    acme.sh --issue / --install-cert / --remove per certificate
  renewal.sls         systemd timer or cron job running acme.sh --cron
  defaults.yaml       every setting and its default
  map.jinja           defaults < OS values < pillar
pillar.example
```

Put the `acme_sh` directory into your file roots (or a gitfs remote), add
pillar like `pillar.example`, and apply `acme_sh`. Sub-states can be applied
on their own, e.g. `state.apply acme_sh.certificates`.

## Declaring certificates

```yaml
acme_sh:
  email: hostmaster@example.com
  certificates:
    www.example.org:
      domains: [www.example.org, example.org]
      challenge: {method: webroot, webroot: /var/www/example.org}
      dest_dir: /etc/nginx/tls/example.org
      pre_hook: logger "requesting cert"
      reload_cmd: systemctl reload nginx
      post_hook: logger "request finished"
```

The key (`www.example.org`) names the certificate inside the formula
(letters, digits, `.`, `_`, `-`). `domains` defaults to `[<key>]`; the first
domain is the name acme.sh files the certificate under.

| Key | Default | Meaning |
|---|---|---|
| `domains` | `[<key>]` | Names on the certificate; wildcards allowed (DNS challenge only) |
| `server` | `letsencrypt` | `letsencrypt_test`, `zerossl`, `buypass`, `google`, or a directory URL |
| `keylength` | `ec-256` | `ec-256`, `ec-384`, `ec-521`, `2048`, `3072`, `4096` |
| `challenge` | – | `method`: `dns` (+ `provider`, optional `challenge_alias`, `domain_alias`, `dnssleep`), `webroot` (+ `webroot`), `standalone` (+ `httpport`), `alpn` (+ `tlsport`), `nginx`, `apache` |
| `env` | `{}` | Environment for `acme.sh --issue`, e.g. DNS API credentials (`CF_Token`). Passed to the command, never put on its command line |
| `dest_dir` | `<dest_base>/<key>` | Directory the files are copied to (`dest_base` defaults to `/etc/ssl/acme`) |
| `files` | `privkey.pem`, `cert.pem`, `chain.pem`, `fullchain.pem` | Keys `key`, `cert`, `ca`, `fullchain`; relative to `dest_dir` or absolute; `null` skips a file |
| `user`, `group` | `root` | Owner of the copied files and of `dest_dir`: a name that exists on the minion, or a numeric ID, quoted or not (e.g. the UID/GID a container runs as) |
| `key_mode`, `cert_mode`, `dir_mode` | `0600`, `0644`, `0755` | Permissions |
| `pre_hook` | – | Commands run before the certificate is requested |
| `reload_cmd` | – | Commands run after the files have been copied |
| `post_hook` | – | Commands run after the request, successful or not (see below) |
| `renew_hook` | – | Commands run after a successful renewal (not on the first issue) |
| `days`, `profile`, `preferred_chain` | – | `--days`, `--cert-profile`, `--preferred-chain` |
| `extra_args` | `[]` | Further `--issue` arguments, one list item per argument |
| `absent` | `false` | Remove the certificate from acme.sh and delete its files |

Anything under `acme_sh:cert_defaults` applies to every certificate. Nested
values merge (a certificate can set only `challenge: {challenge_alias: …}`),
except `env`, which a certificate replaces as a whole so credentials of one
provider don't leak into another certificate's environment.

## What Salt runs

For each certificate, the state output shows the acme.sh commands themselves:

```
/opt/acme.sh/acme.sh --home /opt/acme.sh --config-home /etc/acme.sh --cert-home /etc/acme.sh \
  --issue --server letsencrypt --keylength ec-256 -d www.example.org -d example.org \
  --webroot /var/www/example.org \
  --pre-hook /etc/acme.sh/salt/www.example.org/pre-hook \
  --post-hook /etc/acme.sh/salt/www.example.org/post-hook \
  --renew-hook /etc/acme.sh/salt/www.example.org/renew-hook \
  --key-file /etc/nginx/tls/example.org/privkey.pem ... \
  --reloadcmd /etc/acme.sh/salt/www.example.org/reload --force

/opt/acme.sh/acme.sh ... --install-cert -d www.example.org --key-file ... --reloadcmd ...
```

Whether they need to run is decided from what acme.sh itself records for the
certificate (`Le_CertCreateTime` and `Le_InstallCertSuccessTime` in
`<cert_home>/<domain>[_ecc]/<domain>.conf`), compared with two files Salt
keeps in `/etc/acme.sh/salt/<name>/`:

- **`acme.sh --issue … --force`** runs when there is no certificate yet, or
  `issue.conf` (the issue options and a hash of `env`) changed after the
  last certificate was issued: domains, CA, key type, challenge, `days`,
  `profile`, `extra_args`, credentials. Changing credentials requests a new
  certificate on purpose: acme.sh stores the credentials it used, and only a
  fresh issue makes renewals use the new ones.
- **`acme.sh --install-cert`** copies the files and runs `reload_cmd` without
  contacting the CA. It runs when `install.conf` (destination paths) or the
  `reload_cmd` commands changed, a copied file is missing or differs from
  acme.sh's own copy, or the last install after an issue or renewal did not
  succeed (for example because `reload_cmd` failed). In that last case the
  next Salt run only retries the install; it does not request another
  certificate.
- Otherwise acme.sh is not called and the state reports no changes.

Owner and mode of the copied files are managed by Salt. A file that doesn't
exist yet is created empty with the right owner and mode before acme.sh
writes into it, and acme.sh keeps those on every renewal.

## Hooks

Each hook is a string or a list of commands. The formula writes them to
scripts (`/etc/acme.sh/salt/<name>/pre-hook`, `post-hook`, `renew-hook`,
`reload`; run with `set -e` and a full `PATH`) and gives acme.sh the script
paths, so acme.sh runs them on the first issue *and* on every renewal.
Changing `pre_hook`, `post_hook` or `renew_hook` only rewrites the script; no
new certificate is requested. Changing `reload_cmd` re-runs
`--install-cert`, so the new command runs once right away.

Order, on the first issue and on renewals:

1. `pre_hook`
2. challenge, certificate download
3. files copied to their destination, `reload_cmd`
4. `post_hook`
5. `renew_hook` (renewals only)

acme.sh runs `post_hook` when the challenge or the download fails, but not
when copying the files or `reload_cmd` fails. If you stop a service in
`pre_hook` and start it in `post_hook` (standalone mode on port 80), make
`reload_cmd` something that cannot fail while it is stopped, e.g.
`systemctl try-reload-or-restart …`.

`reload_cmd`, `post_hook` and `renew_hook` can use `$Le_Domain` and acme.sh's
own copies of the files: `$CERT_PATH`, `$CERT_KEY_PATH`, `$CA_CERT_PATH`,
`$CERT_FULLCHAIN_PATH`. `pre_hook` gets `$Le_Domain` and `$Le_Alt`.

## Renewal

`renewal: {method: systemd}` (default) installs `acme-sh-renew.timer`, which
runs `acme.sh --cron` daily (`on_calendar`) and 15 minutes after boot
(`on_boot`, so runs missed while the machine was off are made up);
`method: cron` uses a root cron job instead, `none` disables both. The timer
does not use `Persistent=true`, because that makes systemd require the mount
units for `/var/lib/systemd/timers`, and the timer then fails to start on
hosts where `var.mount` is masked. acme.sh renews every certificate it knows about once it
is due: in 3.1.6 about 30 days after issue (`days` changes that), never later
than a day before expiry, and earlier if the CA asks for it via ARI. On each
renewal acme.sh runs the hooks and copies the files as described above.

## Using acme.sh by hand

With `profile: true` (default), `acme.sh --install` adds acme.sh's usual
alias to root's shell profile, so in a new root shell `acme.sh` already uses
the formula's directories:

```sh
acme.sh --list
acme.sh --renew -d <domain> [--ecc] --force
systemctl list-timers acme-sh-renew.timer
```

With `profile: false`, call it with the directories:
`/opt/acme.sh/acme.sh --home /opt/acme.sh --config-home /etc/acme.sh --list`.

## Notes

- Requires Linux with `git`, `curl`, `openssl` (installed by the formula) and
  acme.sh 3.1.4 or later (it records `Le_InstallCertSuccessTime` since then).
- acme.sh runs as root.
- Pin `version` to an acme.sh release; changing it reinstalls acme.sh.
  Account e-mail changes are written to acme.sh's config but are not pushed to
  CAs you are already registered with (`acme.sh --update-account -m …`).
- acme.sh saves most DNS API credentials once per account
  (`SAVED_<VAR>` in `/etc/acme.sh/account.conf`), not per certificate. Two
  certificates using the same DNS provider with different credentials will
  both renew with whichever credentials were used last.
- Everything in `/etc/acme.sh/salt/<name>/` other than the files above is
  removed on each run.
- With `test=True`, a change to the options shows up on `issue.conf` or
  `install.conf`; the acme.sh commands themselves are evaluated on the real
  run.
