# netboot.xyz: preseeded Debian 13 installs

Unattended Debian 13 (trixie) installs over the network. You pick a host in
the netboot.xyz custom menu. The installer then runs without questions and
leaves a machine with:

- UEFI boot, GPT, and LUKS-encrypted LVM on the disk named in the menu
- a static IP, managed by NetworkManager
- SSH access for root with a key, plus dropbear in the initramfs so the disk
  can be unlocked over SSH at boot
- the backports kernel
- a Salt minion that is connected to the master and has run a highstate

The only thing left to do by hand is to enter the LUKS passphrase on each
boot, either on the console or over SSH.

## Layout

```
menu/trixie.ipxe   netboot.xyz custom menu: one entry per host, builds the kernel command line
assets/preseed/    preseed files and the scripts they run inside the installer
assets/scripts/    post-install scripts, downloaded into the new system by late_command
deploy.sh          copies assets/ (and bootstrap-salt.sh) to the netboot.xyz host
```

## How an install runs

1. **Menu.** `menu/trixie.ipxe` lists the hosts. Choosing one sets that
   host's values and jumps to `:deb13_install`. It shows the kernel command
   line, waits 10 seconds (any key goes back to the menu), and then loads
   the trixie netboot kernel and initrd from `deb.debian.org`.
2. **Network and preseed.** The installer gets an address by DHCP on
   `netcfg/choose_interface` and fetches `preseed/url`
   (`http://<http_server>/preseed/preseed.cfg`). That file pulls in the rest
   of the chain (see [Preseed chain](#preseed-chain)).
3. **Static address.** `preseed/early_command` (`advanced.no_vlan.cfg`) adds
   the host's static IP, default route and both nameservers to the
   installer's network.
4. **Install.** The installer runs with `priority=critical`, so it only
   asks critical questions, and the preseed answers all of them. It does
   the locale, mirror, user, clock, partitioning, base system, apt sources,
   packages and GRUB.
5. **late_command** (`advanced.cfg`). It downloads the scripts from
   `http://<http_server>/scripts/` into `/root/.config/` of the new system and
   runs them there, including a Salt highstate (see
   [Post-install](#post-install)).
6. **Network config.** The installer's own network step writes its config
   for the new system *after* `late_command` (see [Networking](#networking)).
7. **Reboot.** The machine boots into the new system and waits for the LUKS
   passphrase (see [Unlocking the disk](#unlocking-the-disk-at-boot)).

## The iPXE menu

Shared values are set once at the top of `menu/trixie.ipxe`:

| Variable | Used for |
|---|---|
| `http_server` | where `assets/` is served; the source of the preseed and the scripts |
| `di_preseed_url` | `preseed/url` |
| `di_vga`, `di_locale`, `di_domain`, `di_auto`, `di_nameservers` | installer parameters of the same name |
| `net_mask`, `net_gw`, `net_ns_1`, `net_ns_2` | static network settings, the same for all hosts |
| `deb_release`, `deb_arch`, `deb_dir` | where the installer kernel and initrd come from |

Each host has its own block, keyed by a short node name (`w01`, `s03`, ...):

| Variable | Meaning |
|---|---|
| `di_hostname_<node>` | host name (the domain is `di_domain`) |
| `net_dev_<node>` | network interface, e.g. `eno1` |
| `net_ip_<node>` | static IPv4 address |
| `di_disk_<node>` | install disk as its `/dev/disk/by-id/` name, without that prefix. **The whole disk is erased.** |
| `crypto_root_passwd_<node>` | LUKS passphrase |

`di_disk_<node>` is a by-id name, such as
`ata-WDC_WDS120G1G0A-00SS50_172304A01BCC`, and not `sda`. Kernel names can
change between boots, but a by-id name always points to the same physical
disk. To find it, run `ls -l /dev/disk/by-id/ | grep -v -- -part` on the
host. Or set any value, e.g. `unknown`, and boot: the installer stops before
partitioning and lists the IDs of the disks it found. If the value is empty,
the menu refuses to boot the host.

### Kernel command line

`:deb13_install` builds two groups of parameters:

| Parameter | Read by |
|---|---|
| `priority=critical`, `vga`, `locale`, `auto-install/enable` | the installer |
| `hostname`, `domain` | the installer, and `hostname.network.sh` (for dropbear's network config) |
| `netcfg/choose_interface`, `netcfg/get_nameservers`, `partman-auto/disk`, `preseed/url` | the installer; parameters with a `/` become debconf answers |
| `crypto_root_passwd` | `partitioning.crypto-password.sh` |
| `http_server` | `late_command` |
| `net_dev_1`, `net_ip_1`, `net_gw_1`, `net_mask_1`, `net_ns_1`, `net_ns_2` | `early_command`, and `hostname.network.sh`, which saves them for the post-install scripts |

Parameters without a `/` that the kernel doesn't know end up as environment
variables in the installer, which is how `${crypto_root_passwd}` or
`${net_ip_1}` reach the preseed commands and scripts.

Nothing follows the `---` at the end of the kernel line. The installer
copies parameters after `---` into the installed system's GRUB
configuration, so the passphrase stays out of it.

### Adding a host

1. Add a block with the five per-host variables (see above).
2. Add an `item deb13<node> ...` line to `:custom_menu`.
3. Add a `:deb13<node>` stub that copies the values into the `node_*`
   variables and ends with `goto deb13_install`. Copy an existing stub.
4. Create the minion's pillar in the Salt repo (e.g.
   `pillar/nm_connections/<host>.sls`) before installing, so the highstate
   at the end of the install has its data.

## Preseed chain

`preseed.cfg` only includes `localization.cfg`. Each file then includes the
next one with `preseed/include`, so the files load in this order:

| File | Sets |
|---|---|
| `preseed.cfg` | entry point |
| `localization.cfg` | `en_US`, country `DE`, German keyboard |
| `hostname.cfg` | runs `hostname.host.sh` and `hostname.network.sh`; loads missing firmware without asking |
| `mirror.cfg` | `deb.debian.org`, no proxy |
| `password.cfg` | no root password; creates the install user from a password hash |
| `timezone.cfg` | UTC, NTP from `pool.ntp.org` |
| `partitioning.uefi.cfg` | LUKS + LVM layout, see [Partitioning](#partitioning) |
| `base.cfg` | defaults |
| `apt.cfg` | `contrib`, `non-free`, security, updates and backports |
| `packages.cfg` | tasksel `standard`, `openssh-server build-essential dropbear-initramfs vlan lsb-release`, full upgrade, no popcon |
| `bootloader.cfg`, `bootloader.other.cfg` | GRUB to the default device |
| `finishing.cfg` | skip the "installation complete" message |
| `additional.cfg` | `netcfg/target_network_config ifupdown`, see [Networking](#networking) |
| `advanced.cfg` | `late_command`, see [Post-install](#post-install) |
| `advanced.no_vlan.cfg` | `early_command`: static IP, default route, `resolv.conf` |

The installer runs these hooks:

| Hook | Defined in | Runs |
|---|---|---|
| `preseed/run` | `hostname.cfg` | `hostname.host.sh` and `hostname.network.sh`. The latter saves the network values, host name and domain from the kernel command line in `/tmp/net_env.var` |
| `preseed/run` | `partitioning.uefi.cfg` | `partitioning.crypto-password.sh`: puts the LUKS passphrase into debconf |
| `preseed/early_command` | `advanced.no_vlan.cfg` | after the preseed has loaded |
| `partman/early_command` | `partitioning.uefi.cfg` | `partitioning.disk.sh`, after disk detection and before partitioning |
| `preseed/late_command` | `advanced.cfg` | at the end, while the new system is still mounted at `/target` |

### Unused files

These files belong to an older BIOS/software-RAID setup. They are only used
if the commented-out `include_command` lines in `timezone.cfg`,
`bootloader.cfg` and `advanced.cfg` are switched back on:

- `partitioning.cfg`, `partitioning.raid-setup.sh`: BIOS/MBR layout,
  optional software RAID over `sda` and `sdb`
- `bootloader.mt20.cfg`, `bootloader.mt2x.cfg`: GRUB to a fixed disk
- `advanced.vlan.cfg`, `advanced.router.cfg`: installer network on a VLAN

## Partitioning

`partitioning.uefi.cfg` creates this layout on the disk from `di_disk_<node>`:

| Partition / LV | Size | Mount point |
|---|---|---|
| EFI system partition | 538 MB | `/boot/efi` |
| `/boot` | 1 GB, ext4 | `/boot` |
| LUKS container with the LVM volume group `vg0`: | rest of the disk | |
| &nbsp;&nbsp;`root` | 20 GB | `/` |
| &nbsp;&nbsp;`var` | 15 GB | `/var` |
| &nbsp;&nbsp;`containerd` | 50 GB | `/var/lib/containerd` |
| &nbsp;&nbsp;`etcd` | 5 GB | `/var/lib/etcd` |
| &nbsp;&nbsp;`deleteme` | at least 15 GB, takes the rest | `/data` |

All file systems are ext4, mounted by UUID. There is no swap.

- **Free space in `vg0`.** The installer always fills the volume group, so
  `deleteme` takes whatever is left. `lvm-delete.sh` removes it after the
  install, which leaves that space free in `vg0` for later LVs.
- **Minimum disk size.** The minimum sizes add up to about 107 GB, so a
  120 GB disk still fits. On a smaller disk the installer quietly skips this
  layout and uses Debian's default one, without asking.
- **Choosing the disk.** `partitioning.disk.sh` turns the by-id path from the
  kernel command line into the kernel name (e.g. `/dev/sda`), because the
  partitioner only matches kernel names. If the ID is empty or names no disk
  on the machine, it shows a "No usable install disk" screen listing the
  disks and their IDs. Then it switches off automatic partitioning, so no
  disk is touched. If the script can't be downloaded, the installer shows
  "Failed to run preseeded command", and nothing is partitioned either.
- **Passphrase.** The LUKS passphrase comes from `crypto_root_passwd`.
  Passphrases shorter than 8 characters are accepted without a warning. The
  partitions are not wiped before encryption. That saves time, but old data
  stays on the disk until it is overwritten.

## Post-install

`late_command` copies `/tmp/net_env.var` to `/etc/net_env.var` in the new
system, where the scripts read the network values from. It then downloads
the scripts from `assets/scripts/` (plus `bootstrap-salt.sh`) to
`/root/.config/` and runs them in this order inside the new system:

| Script | Does |
|---|---|
| `backports.sh` | installs the kernel and headers from trixie-backports |
| `network.sh` | installs NetworkManager and writes its config, see [Networking](#networking) |
| `lvm-delete.sh` | removes the `deleteme` LV and its `fstab` entry |
| `ssh.sh` | adds the admin's public key to root's `authorized_keys` |
| `dropbear.sh` | sets up dropbear in the initramfs with a static IP and host name (also put into GRUB's kernel line) and a key that may only run `cryptroot-unlock` |
| `bootstrap-salt.sh` | installs Salt `stable 3008` with the host name as minion ID, master `salt-master.klessen.cloud` |
| `salt-call state.highstate` | applies the Salt states |

Finally the installer log is copied to `/root/syslog.setup`, and the
initramfs is rebuilt.

## Networking

The network is set up three times, by different parts:

1. **In the installer:** DHCP, then the static address from
   `early_command`. This network is only used during the install.
2. **For the new system, by `network.sh`.** NetworkManager is not running
   inside the installer, so the script only writes files, and
   NetworkManager reads them on the first boot:
   - It installs `network-manager` and removes `ifupdown` and
     `dhcpcd-base`.
   - It writes `/etc/NetworkManager/conf.d/90-local.conf` with
     `plugins=keyfile` and `no-auto-default=*`. This overrides the packaged
     `NetworkManager.conf`, and also one Salt writes.
   - It writes the static profile `schnorchel-mgmt` for `net_dev_1`, with the
     host's IP, gateway, nameservers and search domain.
   - It stops right at the start, before installing anything, if one of the
     network values from the kernel command line is empty.
3. **By Salt:** if the host has `nm_connections` pillar, the highstate
   rewrites the profiles from pillar. It runs inside the installer too,
   before NetworkManager has ever started, so nothing bounces.

**The installer's network step.** netcfg, the installer's network
component, writes its own network config into the new system after
`late_command` has run. When it finds `network-manager` there, it writes a
DHCP keyfile called `Wired connection 1`. That keyfile matches the same NIC
and wins over `schnorchel-mgmt`, and `no-auto-default=*` doesn't stop it,
because it is a file. `additional.cfg` therefore sets
`netcfg/target_network_config` to `ifupdown`. netcfg then writes
`/etc/network/interfaces` instead, which nothing reads: `ifupdown` is gone,
and NetworkManager only loads the `keyfile` plugin. Keep `plugins=keyfile`
in `90-local.conf`. With the `ifupdown` plugin, NetworkManager would leave
every interface listed in that file unmanaged.

**Profile UUID.** `network.sh` writes `schnorchel-mgmt` with a fixed UUID.
If the host's pillar pins a different one, the highstate replaces the
profile with the pillar's UUID. That happens inside the installer, before
NetworkManager has ever started, so the link doesn't bounce.

## Unlocking the disk at boot

On every boot the initramfs asks for the LUKS passphrase. Either enter it on
the console, or connect over SSH:

```sh
ssh root@<net_ip_<node>>
```

Or use this command to unlock the disk via a command:

```sh
printf '%s' 'my.super.secure.password' | ssh -T root@<node_ip>
```

dropbear listens on the host's static IP and only accepts the admin key,
which runs `cryptroot-unlock` and asks for the passphrase. Port and agent
forwarding are off.

## Deploying

```sh
scripts/netboot.xyz/deploy.sh
```

- It copies `assets/*` with `rsync --delete` into the volume
  `netbootxyz-assets` on `192.168.23.65`. A file deleted here also
  disappears there.
- It copies `3pfs/salt-bootstrap/bootstrap-salt.sh` to `scripts/` in that
  volume.
- The menu expects the files at `http://<http_server>/`
  (`192.168.23.80`).
- `menu/trixie.ipxe` is **not** copied by `deploy.sh`.

The installer kernel and initrd always come from `deb.debian.org`, so the
host needs internet access while it installs.

## Troubleshooting

During the install, Alt+F4 shows the installer log and Alt+F2 opens a shell
(Enter to activate). `/var/log/syslog` has a line from every helper script
(`Start ...`), and from `partitioning.disk.sh` the disk it chose.

| Symptom | Cause |
|---|---|
| "ERROR: no install disk set" in the menu | `di_disk_<node>` is empty |
| "No usable install disk" in the installer | `di_disk_<node>` names no disk on this machine. The screen lists the IDs it found |
| "Failed to run preseeded command" before partitioning | `partitioning.disk.sh` could not be downloaded from `http_server` |
| Installer asks for the partitioning method | follows one of the two errors above. Abort the install |
| Unexpected layout (one big root, swap) | the disk is smaller than ~107 GB |
| New system uses DHCP, `Wired connection 1` in `/etc/NetworkManager/system-connections/` | netcfg wrote its NetworkManager profile; check `netcfg/target_network_config` in `additional.cfg` |
| No NetworkManager profile at all after the install | `network.sh` stopped early; look for its output in `/root/syslog.setup` |

After the install, `/root/syslog.setup` has the full installer log, including
the output of the post-install scripts.

## Security notes

- **LUKS passphrases** are in plain text in `menu/trixie.ipxe`. The menu
  shows them on screen as part of the kernel command line, and they are in
  `/proc/cmdline` during the install. They are not copied to the installed
  system's GRUB configuration.
- **Plain HTTP.** The preseed files and scripts are served over plain HTTP
  without authentication. Anyone on the network can read them, including
  the install user's password hash in `password.cfg`. Anyone who can answer
  for `http_server` can also serve scripts that run as root in the new
  system.
- **Salt key.** The master accepts new minion keys automatically
  (`config/00-auto_accept.conf` in the Salt repo), so any machine that
  installs this way becomes a minion.
