# quadlet-formula

Salt formula that rolls out rootful [Podman Quadlets](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html) from pillar. A quadlet here is an **app**: one or more containers in their own directory `/etc/containers/systemd/<app>/`. An app with several containers runs them in a **pod**, so they share one network namespace (`localhost`). Every app is attached to one shared **macvlan** network with a configurable static **IP and MAC address**, and can use any number of **volumes** (named podman volumes shared by its containers, host directories, or raw `--volume` specs).

Rendering was checked with a masterless Salt 3007 run. The generated units have not yet been run through Podman's quadlet generator in this layout.

## Requirements

- Podman 5.0 or newer: `.pod` units and quadlets in subdirectories (Debian 13 ships 5.4)
- systemd with cgroup v2
- Rootful: macvlan with fixed addresses does not work rootless, so units go to `/etc/containers/systemd`

## Usage

```yaml
# top.sls
base:
  'container-host*':
    - quadlets
```

| State                 | Does                                                                   |
| --------------------- | ---------------------------------------------------------------------- |
| `quadlets`            | Everything below. Use this one.                                        |
| `quadlets.package`    | Installs podman                                                        |
| `quadlets.config`     | Quadlet directory, `systemctl daemon-reload` when any unit changed     |
| `quadlets.network`    | The macvlan `.network` unit and its service                            |
| `quadlets.apps`       | App directories, `.pod`/`.container`/`.volume` units, bind dirs, image pulls, services |
| `quadlets.clean`      | Stops and removes apps that left the pillar or are `absent: true`      |

## Pillar

See `pillar.example.sls` for a complete, commented example. Minimal:

```yaml
quadlets:
  network:
    name: lan
    parent: eth0
    subnet: 192.168.10.0/24
    gateway: 192.168.10.1
  apps:
    web:
      ip: 192.168.10.50
      mac: '02:42:c0:a8:0a:32'
      volumes:
        html: {}                     # podman volume "web-html"
      containers:
        web:
          image: docker.io/library/nginx:1.27
          volumes:
            - volume: html
              target: /usr/share/nginx/html
            - source: /srv/web/conf.d    # host dir, created if missing
              target: /etc/nginx/conf.d
              options: [ro, Z]
```

This writes `lan.network`, `web/web.container` and `web/web-html.volume` below `/etc/containers/systemd`, and runs `web.service` with container name `web` at 192.168.10.50 / 02:42:c0:a8:0a:32.

### `quadlets:network`

| Key                  | Default   | Meaning                                                                 |
| -------------------- | --------- | ----------------------------------------------------------------------- |
| `name`               | `macvlan` | Unit file `<name>.network`, podman network `<name>`, service `<name>-network.service` |
| `parent`             | required  | Host interface (`eth0`, `bond0.20`, …)                                  |
| `subnet`             | required  | CIDR, string or list (add an IPv6 subnet + `ipv6: true` for dual stack) |
| `gateway`            |           | String or list                                                          |
| `ip_range`           |           | Pool for apps without a static `ip`                                     |
| `mode`               |           | macvlan mode: `bridge`, `private`, `vepa`, `passthru`                   |
| `ipv6`               | `false`   |                                                                         |
| `options`            | `{}`      | Extra driver options, e.g. `mtu: 9000`                                  |
| `recreate_on_change` | `true`    | See *Network changes* below                                             |
| `Network`, `Unit`, … |           | Raw unit sections                                                       |

The network is shared by all apps, so its unit stays directly in `/etc/containers/systemd`.

### `quadlets:apps:<app>`

| Key             | Default   | Meaning                                                                     |
| --------------- | --------- | --------------------------------------------------------------------------- |
| `containers`    | required  | Mapping of container name to settings, see below                            |
| `pod`           | `auto`    | `auto`: a pod when there is more than one container. `true`: always. `false`: never (one container only) |
| `ip` / `ip6`    |           | Static address on the macvlan; must lie inside `subnet`                     |
| `mac`           |           | Static MAC, **quoted**. `auto` derives `02:42:<ip in hex>` from `ip`         |
| `hostname`      | `<app>`   |                                                                             |
| `dns`           |           | String or list                                                              |
| `description`   |           | `[Unit] Description=` of the pod, or of the single container               |
| `volumes`       | `{}`      | Named podman volumes of this app, see below                                 |
| `running`       | `true`    | `false` keeps the units but stops the services                              |
| `enabled`       | `true`    | `false` drops `[Install]`, so nothing starts at boot                        |
| `absent`        | `false`   | Stop the services and delete the app's units and directory                  |
| `purge_volumes` | `false`   | With `absent`, also `podman volume rm` its named volumes                     |
| `Pod`, `Unit`, `Service`, `Install` | | Raw sections of the `.pod` unit (pods only)                |

`ip`, `mac`, `hostname` and `dns` belong to the app: in a pod they are set on the pod (the containers share its network namespace), otherwise on the single container.

Unit names follow the app name. The pod is `<app>.pod` → `<app>-pod.service`, pod name `<app>`. A container with the same name as its app is `<app>.container` → `<app>.service`, every other one is `<app>-<container>.container` → `<app>-<container>.service`. Container names default to the unit name.

### `quadlets:apps:<app>:containers:<name>`

| Key                 | Default        | Meaning                                                             |
| ------------------- | -------------- | ------------------------------------------------------------------- |
| `image`             | required       | Fully qualified image (or a `.image`/`.build` quadlet reference)     |
| `container_name`    | unit name      | Podman container name                                               |
| `description`       |                | `[Unit] Description=`                                               |
| `environment`       | `{}`           | Mapping. Values are literal: `%` and `$` are escaped for systemd     |
| `environment_files` |                | String or list                                                      |
| `labels`            | `{}`           | Mapping                                                             |
| `command`           |                | `Exec=` (arguments after the image)                                 |
| `entrypoint`, `user`, `group`, `auto_update` | | Map to the Quadlet keys of the same name                  |
| `volumes`           | `[]`           | Mounts, see below                                                   |
| `pull`              | `true`         | Pre-pull the image during the Salt run                              |
| `Container`, `Unit`, `Service`, `Install`, `Quadlet` | | Raw unit sections, written as-is      |

`quadlets:container_defaults` is merged into every container. By default it sets `Restart=always`, `TimeoutStartSec=900` and `WantedBy=multi-user.target`. `quadlets:pod_defaults` does the same for pods (`WantedBy=multi-user.target`).

**Raw sections.** Any capitalized key is a unit section and its keys go into the file unchanged. A list value repeats the key:

```yaml
Container:
  AddCapability: [NET_ADMIN, SYS_NICE]
  Secret: db-pass,type=env,target=DB_PASS
Service:
  Restart: on-failure
```

In a pod, `Network`, `IP`, `IP6`, `HostName`, `DNS` and `PublishPort` are rejected under a container's `Container:`; set them on the app, or under the app's `Pod:`.

### Volumes

Named volumes are defined once per app and mounted by any of its containers:

```yaml
apps:
  app:
    volumes:
      # <app>-<name>.volume; the podman volume is called <app>-<name>
      # unless volume_name is set.
      data: {}
      legacy:
        volume_name: legacy-data      # adopt an existing podman volume
      share:
        Volume:                       # optional raw [Volume] keys
          Device: //nas/share
          Type: cifs
          Options: credentials=/etc/nas-cred
```

Each entry in a container's `volumes` is one of:

```yaml
volumes:
  # A volume of this app
  - volume: data
    target: /var/lib/app
    options: Z                    # string or list: ro, z, Z, U, ...

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
  - other-app-data.volume:/shared   # share another app's named volume
```

## Behaviour

- **Validation.** A broken pillar aborts rendering with a list of every problem, before anything is changed. It checks for: missing image, unknown option (typo), app settings on a container and vice versa, IP outside the subnet or equal to the gateway, duplicate IP/MAC across apps, malformed or multicast MAC, unquoted MAC, mounts of undefined volumes, volumes without target or with relative paths, pod-owned keys on pod containers, clashing unit names, and a hand-written unit with the same file name elsewhere under `/etc/containers/systemd` (Quadlet unit names are global across subdirectories).
- **Changes** to a `.container` or `.volume` unit trigger one `daemon-reload` and a restart of the containers using it. A changed `.pod` restarts the pod and its containers.
- **Images** are pulled during the Salt run, so a slow pull never hits the systemd start timeout and a typo fails the highstate.
- **Network changes.** Podman never updates an existing network from a changed `.network` unit. With `recreate_on_change` the formula stops everything attached (systemd propagates the stop through `Requires=`), removes the podman network and starts everything again on the new network. This is skipped on the very first rollout, so a pre-existing network with the same name is never deleted.
- **Removal.** Deleting an app or a container from pillar, or setting `absent: true`, stops the services and deletes the unit files before any new container starts, so an IP or MAC can be reused in the same run. An app directory is deleted once nothing but such files is left in it. Only files with the formula's header line are touched; hand-written quadlets are left alone. Units from the earlier flat layout (directly in `/etc/containers/systemd`) are cleaned up the same way. Named volume data is kept unless `purge_volumes: true`.
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
- Unit names are global. An app called `nginx` generates `nginx.service` and shadows a distro `nginx.service`.
