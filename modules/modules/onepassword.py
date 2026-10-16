"""
Retrieve secrets from 1Password with the ``op`` CLI.

:depends: 1Password CLI (``op``) 2.18+ on the host that renders the template,
          authenticated with a 1Password service account or a Connect server.

Where it should run
-------------------
Recommended: on the **Salt master**, inside pillar SLS files. Only the master
then needs ``op`` and the token, each minion receives only the secrets its
pillar targets, and states/templates read them from pillar like any other
value.

It also works on a minion (calling ``salt['onepassword.read'](...)`` directly
in a state or template), but then every minion needs ``op`` plus a token that
can read the vault, which widens the blast radius considerably. Hosts without
``op`` simply don't load this module.

Configuration
-------------
Master config (e.g. ``/etc/salt/master.d/onepassword.conf``) for pillar use,
minion config for minion-side use. Never put the token in pillar.

.. code-block:: yaml

    onepassword:
      # Service account token in a file only the salt-master user can read
      token_file: /etc/salt/onepassword.token
      # ...or a Connect server (wins over the service account if both are set)
      # connect_host: https://op-connect.example.com:8080
      # connect_token_file: /etc/salt/onepassword-connect.token
      op_bin: /usr/local/bin/op     # default: "op" from PATH
      timeout: 30                   # seconds per op call
      cache_ttl: 300                # in-memory cache per process; 0 = off
      # account: example.1password.eu        # only for non-service-account sign-ins
      # config_dir: /var/lib/salt/.config/op # if the daemon user's HOME isn't writable
      # cli_cache: false                     # op's own cache daemon (OP_CACHE)

``token`` / ``connect_token`` may be given inline instead of the ``*_file``
keys, but a 0400 file keeps the token out of config dumps. With nothing
configured, whatever ``OP_*`` variables the daemon was started with are used.

Usage
-----
Pillar SLS, rendered on the master:

.. code-block:: jinja

    myapp:
      db_user: {{ salt['onepassword.read']('op://Infra/myapp-db/username') | yaml_dquote }}
      db_password: {{ salt['onepassword.get']('Infra', 'myapp-db') | yaml_dquote }}

Always pipe values through ``yaml_dquote`` in pillar: a password containing
``": "`` or ``" #"``, or one that looks like ``yes`` or ``0123``, otherwise
breaks the YAML or silently changes type.

State and template:

.. code-block:: yaml

    /etc/myapp/db.conf:
      file.managed:
        - source: salt://myapp/files/db.conf.j2
        - template: jinja
        - mode: '0600'
        - show_changes: False   # keep secrets out of diffs and job returns

    # db.conf.j2
    password={{ pillar['myapp']['db_password'] }}

Quick checks on the master (runs the module in the master's context):

.. code-block:: bash

    salt-run salt.cmd onepassword.version
    salt-run salt.cmd onepassword.read 'op://Infra/myapp-db/password'
    salt-run salt.cmd onepassword.ratelimit

Rate limits and caching
-----------------------
Service accounts are rate limited (as of 2026, 1Password Business allows
10,000 reads/hour per token and 50,000 requests/day per account), and pillar
is rendered again for every minion on every refresh. ``op read`` costs 3
reads when vault and item are given by name and 1 when given by ID
(``op://<vault-id>/<item-id>/password``).

This module fetches each reference once per render (``__context__``) and
keeps values in process memory for ``cache_ttl`` seconds, so a rotated secret
reaches minions within that window (restart the master to flush at once).
Nothing is written to disk. For large fleets a Connect server, which has no
request quotas, is the better backend; ``op`` uses it when ``connect_host``
is set.

Errors
------
Every failure raises ``CommandExecutionError``, so the pillar or template
fails to render instead of deploying an empty password. Secret values are
never logged.
"""

import hashlib
import json
import logging
import os
import stat
import subprocess
import sys
import threading
import time
import types

import salt.utils.files
import salt.utils.path
from salt.exceptions import CommandExecutionError, SaltInvocationError

log = logging.getLogger(__name__)

__virtualname__ = "onepassword"

_DEFAULTS = {
    "op_bin": "op",
    "token": None,
    "token_file": None,
    "connect_host": None,
    "connect_token": None,
    "connect_token_file": None,
    "account": None,
    "config_dir": None,
    "timeout": 30,
    "cache_ttl": 300,
    "cli_cache": False,
}

_REF_PREFIX = "op://"
_CONTEXT_KEY = "onepassword.values"
# Lives in sys.modules so it survives across loader instances in a
# long-running process (each pillar compile builds a fresh loader).
_PROC_CACHE = "_salt_ext_onepassword_cache"


def __virtual__():
    raw = __opts__.get("onepassword")
    if raw is not None and not isinstance(raw, dict):
        return (False, "onepassword: config key 'onepassword' must be a mapping")
    unknown = sorted(set(raw or {}) - set(_DEFAULTS))
    if unknown:
        log.warning("onepassword: ignoring unknown config keys: %s", ", ".join(unknown))
    op_bin = _conf()["op_bin"]
    if _find_op(op_bin):
        return __virtualname__
    return (False, f"onepassword: 1Password CLI '{op_bin}' not found or not executable")


# --------------------------------------------------------------------------
# internals
# --------------------------------------------------------------------------


def _conf():
    raw = __opts__.get("onepassword") or {}
    conf = dict(_DEFAULTS)
    if isinstance(raw, dict):
        conf.update({k: v for k, v in raw.items() if k in _DEFAULTS})
    return conf


def _find_op(op_bin):
    op_bin = str(op_bin)
    if os.sep in op_bin:
        if os.path.isfile(op_bin) and os.access(op_bin, os.X_OK):
            return op_bin
        return None
    return salt.utils.path.which(op_bin)


def _load_secret(conf, key):
    """Return the token configured as ``<key>_file`` or ``<key>``, or None."""
    path = conf.get(key + "_file")
    if path:
        try:
            mode = stat.S_IMODE(os.stat(path).st_mode)
            with salt.utils.files.fopen(path, "r") as fh:
                value = fh.read().strip()
        except OSError as exc:
            raise CommandExecutionError(
                f"onepassword: cannot read {key}_file {path}: {exc.strerror}"
            )
        if mode & (stat.S_IRWXG | stat.S_IRWXO):
            log.warning(
                "onepassword: %s_file %s is accessible to group/other (mode %04o); use 0400",
                key,
                path,
                mode,
            )
        if not value:
            raise CommandExecutionError(f"onepassword: {key}_file {path} is empty")
        return value
    value = conf.get(key)
    return str(value).strip() if value else None


def _build_env(conf):
    """Return (environment for op, fingerprint of the credentials in use)."""
    env = os.environ.copy()
    connect_host = conf.get("connect_host")
    if connect_host:
        token = _load_secret(conf, "connect_token")
        if not token:
            raise CommandExecutionError(
                "onepassword: connect_host is set but connect_token/connect_token_file is not"
            )
        env.pop("OP_SERVICE_ACCOUNT_TOKEN", None)
        env["OP_CONNECT_HOST"] = str(connect_host)
        env["OP_CONNECT_TOKEN"] = token
        identity = f"connect|{connect_host}|{token}"
    else:
        token = _load_secret(conf, "token")
        if token:
            # OP_CONNECT_* would take precedence over the service account.
            env.pop("OP_CONNECT_HOST", None)
            env.pop("OP_CONNECT_TOKEN", None)
            env["OP_SERVICE_ACCOUNT_TOKEN"] = token
            identity = f"sa|{token}"
        else:
            identity = "env|" + "|".join(
                env.get(var, "")
                for var in (
                    "OP_CONNECT_HOST",
                    "OP_CONNECT_TOKEN",
                    "OP_SERVICE_ACCOUNT_TOKEN",
                    "OP_ACCOUNT",
                )
            )
    if not conf.get("cli_cache"):
        env["OP_CACHE"] = "false"
    identity += f"|{conf.get('account')}"
    return env, hashlib.sha256(identity.encode("utf-8")).hexdigest()


def _run_op(conf, env, subcommand, positionals=(), global_flags=True):
    """Run op and return stdout as bytes. Raises CommandExecutionError."""
    op_bin = _find_op(conf["op_bin"]) or str(conf["op_bin"])
    cmd = [op_bin] + list(subcommand)
    if global_flags:
        if conf.get("account"):
            cmd.append(f"--account={conf['account']}")
        if conf.get("config_dir"):
            cmd.append(f"--config={conf['config_dir']}")
    cmd += list(positionals)

    shown = " ".join([s for s in subcommand if not s.startswith("-")] + list(positionals))
    timeout = float(conf.get("timeout") or 30)
    log.debug("onepassword: running op %s", shown)
    try:
        proc = subprocess.run(
            cmd,
            stdin=subprocess.DEVNULL,  # never let op prompt for anything
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        raise CommandExecutionError(f"onepassword: 'op {shown}' timed out after {timeout:g}s")
    except OSError as exc:
        raise CommandExecutionError(f"onepassword: cannot execute {op_bin}: {exc.strerror}")
    if proc.returncode != 0:
        err = proc.stderr.decode("utf-8", "replace").strip() or f"exit code {proc.returncode}"
        raise CommandExecutionError(f"onepassword: 'op {shown}' failed: {err}")
    return proc.stdout


def _proc_store():
    store = sys.modules.get(_PROC_CACHE)
    if store is None:
        store = types.ModuleType(_PROC_CACHE)
        store.lock = threading.Lock()
        store.entries = {}
        store = sys.modules.setdefault(_PROC_CACHE, store)
    return store


def _cached(conf, kind, key_parts, fetch):
    """Return fetch(env), deduplicated per run and cached per process for cache_ttl."""
    env, fingerprint = _build_env(conf)
    key = (fingerprint, kind) + tuple(key_parts)

    run_cache = __context__.setdefault(_CONTEXT_KEY, {})
    if key in run_cache:
        return run_cache[key]

    try:
        ttl = float(conf.get("cache_ttl") or 0)
    except (TypeError, ValueError):
        ttl = 0.0
    store = _proc_store() if ttl > 0 else None
    if store is not None:
        with store.lock:
            hit = store.entries.get(key)
        if hit is not None and hit[0] > time.monotonic():
            run_cache[key] = hit[1]
            return hit[1]

    value = fetch(env)  # raises on failure; failures are never cached
    run_cache[key] = value
    if store is not None:
        now = time.monotonic()
        with store.lock:
            for stale in [k for k, (exp, _) in store.entries.items() if exp <= now]:
                del store.entries[stale]
            store.entries[key] = (now + ttl, value)
    return value


def _check_reference(reference):
    if not isinstance(reference, str):
        raise SaltInvocationError("onepassword: secret reference must be a string")
    ref = reference.strip()
    path = ref[len(_REF_PREFIX):].split("?", 1)[0]
    if (
        not ref.startswith(_REF_PREFIX)
        or len([p for p in path.split("/") if p]) < 3
        or any(c in ref for c in "\r\n\0")
    ):
        raise SaltInvocationError(
            f"onepassword: expected a secret reference like op://vault/item/field, got {ref!r}"
        )
    return ref


def _check_name(value, what):
    if value is None:
        raise SaltInvocationError(f"onepassword: {what} is required")
    name = str(value).strip()
    if not name or "/" in name or name.startswith("-") or any(c in name for c in "\r\n\0"):
        raise SaltInvocationError(
            f"onepassword: invalid {what} {name!r}; use the 1Password ID for names "
            "containing '/' or starting with '-'"
        )
    return name


def _fields_map(data):
    fields = {}
    for field in data.get("fields") or []:
        if "value" not in field:
            continue
        label = field.get("label") or field.get("id")
        if not label:
            continue
        section = (field.get("section") or {}).get("label")
        if section:
            fields.setdefault(f"{section}/{label}", field["value"])
        fields.setdefault(label, field["value"])
    return fields


# --------------------------------------------------------------------------
# public functions
# --------------------------------------------------------------------------


def read(reference):
    """
    Return the value a 1Password secret reference points to (``op read``).

    reference
        ``op://<vault>/<item>/[<section>/]<field>``, optionally with a query
        such as ``?attribute=otp``. Vault and item IDs instead of names cost
        fewer API requests.

    CLI Example:

    .. code-block:: bash

        salt-call onepassword.read 'op://Infra/myapp-db/password'
        salt-run salt.cmd onepassword.read 'op://Infra/myapp-db/password'

    Jinja (pillar):

    .. code-block:: jinja

        db_password: {{ salt['onepassword.read']('op://Infra/myapp-db/password') | yaml_dquote }}
    """
    conf = _conf()
    ref = _check_reference(reference)

    def fetch(env):
        out = _run_op(conf, env, ["read", "--no-newline"], [ref])
        try:
            return out.decode("utf-8")
        except UnicodeDecodeError:
            raise CommandExecutionError(
                f"onepassword: {ref} is not UTF-8 text (binary file attachment?)"
            )

    return _cached(conf, "read", (ref,), fetch)


def get(vault, item, field="password", section=None):
    """
    Return one field of an item; builds the secret reference for you.

    vault
        Vault name or ID.
    item
        Item name or ID.
    field
        Field label or ID. Default: ``password``.
    section
        Section label or ID, for fields that live in a custom section.

    CLI Example:

    .. code-block:: bash

        salt-call onepassword.get Infra myapp-db
        salt-call onepassword.get Infra myapp-db field=username
        salt-call onepassword.get Infra myapp-db field=port section=Connection
    """
    parts = [_check_name(vault, "vault"), _check_name(item, "item")]
    if section:
        parts.append(_check_name(section, "section"))
    parts.append(_check_name(field, "field"))
    return read(_REF_PREFIX + "/".join(parts))


def item(vault, item):
    """
    Return all fields of an item as ``{label: value}`` with one ``op`` call,
    for templates that need several fields of the same item. Fields in a
    custom section are also available as ``"<section>/<label>"``; when two
    fields share a label, the first one wins under the bare label.

    vault
        Vault name or ID (required with service accounts).
    item
        Item name or ID.

    CLI Example:

    .. code-block:: bash

        salt-call onepassword.item Infra myapp-db

    Jinja (pillar):

    .. code-block:: jinja

        {%- set db = salt['onepassword.item']('Infra', 'myapp-db') %}
        myapp:
          db_user: {{ db['username'] | yaml_dquote }}
          db_password: {{ db['password'] | yaml_dquote }}
    """
    conf = _conf()
    vault = _check_name(vault, "vault")
    item = _check_name(item, "item")

    def fetch(env):
        base = ["item", "get", "--format=json", f"--vault={vault}"]
        try:
            out = _run_op(conf, env, base + ["--reveal"], [item])
        except CommandExecutionError as exc:
            # Older CLI releases don't know --reveal and print values anyway.
            if "unknown flag" not in str(exc) or "reveal" not in str(exc):
                raise
            out = _run_op(conf, env, base, [item])
        try:
            data = json.loads(out.decode("utf-8"))
        except ValueError:
            raise CommandExecutionError(
                f"onepassword: unexpected (non-JSON) output from 'op item get {item}'"
            )
        return _fields_map(data)

    return dict(_cached(conf, "item", (vault, item), fetch))


def ratelimit():
    """
    Show the service account's current rate-limit usage
    (``op service-account ratelimit``). Not cached; not available via Connect.

    CLI Example:

    .. code-block:: bash

        salt-run salt.cmd onepassword.ratelimit
    """
    conf = _conf()
    env, _ = _build_env(conf)
    out = _run_op(conf, env, ["service-account", "ratelimit", "--format=json"])
    text = out.decode("utf-8", "replace").strip()
    try:
        return json.loads(text)
    except ValueError:
        return text


def version():
    """
    Return the installed ``op`` version. Makes no API request.

    CLI Example:

    .. code-block:: bash

        salt-run salt.cmd onepassword.version
    """
    conf = _conf()
    out = _run_op(conf, os.environ.copy(), ["--version"], global_flags=False)
    return out.decode("utf-8", "replace").strip()
