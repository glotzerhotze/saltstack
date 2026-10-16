# quadlet-formula

Salt formula that rolls out rootful [Podman Quadlets](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) from pillar. Every quadlet is attached to one shared **macvlan** network with a configurable static **IP and MAC address**, and can mount any number of **volumes** (named podman volumes, host directories, or raw `--volume` specs).

Tested with Salt 3007.15 and Podman 4.9.3 (Ubuntu 24.04). The generated units were checked with Podman's own quadlet generator, and the network attachment it produces (`--network=lan:ip=…,mac=…`) was verified on a real macvlan.

## Requirements

- Podman 4.9 or newer with Quadlet (Debian 12's 4.3 has no Quadlet)
- systemd with cgroup v2
- Rootful: macvlan with fixed addresses does not work rootless, so units go to `/etc/containers/systemd`

## Usage

```yaml
# top.sls
base:
  'container-host*':
    - quadlet
```

| State                | Does                                                                   |
| -------------------- | ---------------------------------------------------------------------- |
| `quadlet`            | Everything below. Use this one.                                         |
| `quadlet.package`    | Installs podman                                                         |
| `quadlet.config`     | Quadlet directory, `systemctl daemon-reload` when any unit changed     |
| `quadlet.network`    | The macvlan `.network` unit and its service                            |
| `quadlet.containers` | `.container` + `.volume` units, bind dirs, image pulls, services       |
| `quadlet.clean`      | Stops and removes quadlets that left the pillar or are `absent: true`  |

## Pillar

See `pillar.example.sls` for a complete, commented example. Minimal:

```yaml
quadlet:
  network:
    name: lan
    parent: eth0
    subnet: 192.168.10.0/24
    gateway: 192.168.10.1
  containers:
    web:
      image: docker.io/library/nginx:1.27
      ip: 192.168.10.50
      mac: '02:42:c0:a8:0a:32'
      volumes:
        - name: html                 # podman volume "web-html"
          target: /usr/share/nginx/html
        - source: /srv/web/conf.d    # host dir, created if missing
          target: /etc/nginx/conf.d
          options: [ro, Z]
```

This writes `lan.network`, `web.container` and `web-html.volume`, and runs `web.service` with container name `web` at 192.168.10.50 / 02:42:c0:a8:0a:32.

### `quadlet:network`

| Key                  | Default   | Meaning                                                                 |
| -------------------- | --------- | ----------------------------------------------------------------------- |
| `name`               | `macvlan` | Unit file `<name>.network`, podman network `<name>`, service `<name>-network.service` |
| `parent`             | required  | Host interface (`eth0`, `bond0.20`, …)                                  |
| `subnet`             | required  | CIDR, string or list (add an IPv6 subnet + `ipv6: true` for dual stack) |
| `gateway`            |           | String or list                                                          |
| `ip_range`           |           | Pool for quadlets without a static `ip`                                 |
| `mode`               |           | macvlan mode: `bridge`, `private`, `vepa`, `passthru`                   |
| `ipv6`               | `false`   |                                                                         |
| `options`            | `{}`      | Extra driver options, e.g. `mtu: 9000`                                  |
| `recreate_on_change` | `true`    | See *Network changes* below                                             |
| `Network`, `Unit`, … |           | Raw unit sections                                                       |

### `quadlet:containers:<name>`

| Key                 | Default        | Meaning                                                             |
| ------------------- | -------------- | ------------------------------------------------------------------- |
| `image`             | required       | Fully qualified image (or a `.image`/`.build` quadlet reference)     |
| `ip` / `ip6`        |                | Static address on the macvlan; must lie inside `subnet`             |
| `mac`               |                | Static MAC, **quoted**. `auto` derives `02:42:<ip in hex>` from `ip` |
| `hostname`          | `<name>`       |                                                                     |
| `container_name`    | `<name>`       | Podman container name                                               |
| `description`       |                | `[Unit] Description=`                                               |
| `dns`               |                | String or list                                                      |
| `environment`       | `{}`           | Mapping. Values are literal: `%` and `$` are escaped for systemd     |
| `environment_files` |                | String or list                                                      |
| `labels`            | `{}`           | Mapping                                                             |
| `command`           |                | `Exec=` (arguments after the image)                                 |
| `entrypoint`, `user`, `group`, `auto_update` | | Map to the Quadlet keys of the same name                  |
| `volumes`           | `[]`           | See below                                                           |
| `running`           | `true`         | `false` keeps the unit but stops the service                        |
| `enabled`           | `true`         | `false` drops `[Install]`, so it does not start at boot             |
| `pull`              | `true`         | Pre-pull the image during the Salt run                              |
| `absent`            | `false`        | Stop the service and delete its units                               |
| `purge_volumes`     | `false`        | With `absent`, also `podman volume rm` its named volumes            |
| `Container`, `Unit`, `Service`, `Install`, `Quadlet` | | Raw unit sections, written as-is      |

`quadlet:container_defaults` is merged into every container. By default it sets `Restart=always`, `TimeoutStartSec=900` and `WantedBy=multi-user.target`.

**Raw sections.** Any capitalized key is a unit section and its keys go into the file unchanged. A list value repeats the key:

```yaml
Container:
  AddCapability: [NET_ADMIN, SYS_NICE]
  Secret: db-pass,type=env,target=DB_PASS
Service:
  Restart: on-failure
```

### Volumes

Each entry in `volumes` is one of:

```yaml
volumes:
  # Named podman volume. Gets its own <container>-<name>.volume unit;
  # the podman volume is called <container>-<name> unless volume_name is set.
  - name: data
    target: /var/lib/app
    options: Z                    # string or list: ro, z, Z, U, ...
    volume_name: legacy-data      # optional: adopt an existing podman volume
    Volume:                       # optional raw [Volume] keys
      Device: //nas/share
      Type: cifs
      Options: credentials=/etc/nas-cred

  # Host path (bind mount). Missing paths are created as directories;
  # existing files (e.g. /etc/localtime) are left alone.
  - source: /srv/app/config
    target: /config
    options: [ro, Z]
    create: true                  # default
    user: root                    # owner/mode for the created directory
    group: root
    mode: '0750'

  # Raw podman --volume spec, passed through unchanged
  - /etc/localtime:/etc/localtime:ro
  - other-app-data.volume:/shared   # share another quadlet's named volume
```

## Behaviour

- **Validation.** A broken pillar aborts rendering with a list of every problem, before anything is changed. It checks for: missing image, unknown option (typo), IP outside the subnet or equal to the gateway, duplicate IP/MAC across quadlets, malformed or multicast MAC, unquoted MAC, and volumes without target or with relative paths.
- **Changes** to a `.container` or `.volume` unit trigger one `daemon-reload` and a restart of that container only.
- **Images** are pulled during the Salt run, so a slow pull never hits the systemd start timeout and a typo fails the highstate.
- **Network changes.** Podman never updates an existing network from a changed `.network` unit. With `recreate_on_change` the formula stops the attached quadlets (systemd propagates the stop through `Requires=`), removes the podman network and starts everything again on the new network. This is skipped on the very first rollout, so a pre-existing network with the same name is never deleted.
- **Removal.** Deleting a container from pillar, or setting `absent: true`, stops its service and deletes its unit files before any new container starts, so an IP or MAC can be reused in the same run. Only files with the formula's header line are touched; hand-written quadlets in the same directory are left alone. Named volume data is kept unless `purge_volumes: true`.
- **Boot.** Quadlet services cannot be `systemctl enable`d. Boot start comes from the `[Install]` section that the generator applies. `enabled: false` removes it.

## Things to know about macvlan

- **The host cannot reach its own macvlan containers** through the parent interface, which is a kernel restriction. If the host needs access, give it a macvlan "shim" interface on the same parent, for example:

  ```sh
  ip link add lan-shim link eth0 type macvlan mode bridge
  ip addr add 192.168.10.254/32 dev lan-shim
  ip link set lan-shim up
  ip route add 192.168.10.48/28 dev lan-shim   # the container range
  ```

  Make this persistent with systemd-networkd or NetworkManager.
- Use **locally administered unicast MACs**: the first octet is `x2`, `x6`, `xA` or `xE`, for example `02:…`. Always quote them in YAML. Unquoted values like `12:34:56:00:11:22` become a base-60 number.
- Keep static IPs out of your DHCP server's pool, and out of `ip_range` if you set one.
- Some switches and Wi-Fi access points drop frames from multiple MACs on one port. On Wi-Fi, use `ipvlan` instead (`network: {driver: ipvlan}`); MACs then don't apply.
- Unit names are global. A quadlet called `nginx` generates `nginx.service` and shadows a distro `nginx.service`.
