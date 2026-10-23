# luks_lvm formula

Salt formula for LVM on LUKS on Debian 13 (trixie). Disks are identified by
`/dev/disk/by-id/...` in pillar. Every disk gets its own LUKS2 container;
LVM sits on top, and LVs are formatted and mounted where the pillar says.

Disks that are **already LUKS** are never reformatted: they are unlocked with
the key from pillar and their contents are mounted at the pillar's
mountpoints.

## What happens to each disk

| Disk state                                   | Result                                                                 |
|----------------------------------------------|------------------------------------------------------------------------|
| Blank (no signature at all)                  | `luksFormat` (LUKS2) → unlock → PV/VG/LVs → mkfs → mount               |
| Already LUKS                                 | unlock → use existing PV/VG/LVs/filesystem → mount                     |
| Anything else (filesystem, partition table…) | **state fails**, nothing touched. Run `wipefs -a <disk>` yourself first |

Inside an unlocked container the same rule applies one level down:

* `pvcreate` only runs on an empty container (Salt's `pvcreate` passes
  `--yes`, so the formula guards it); a container holding a filesystem while
  the pillar says `vg:` makes the state fail.
* `mkfs` only runs on a device with no signature, so existing filesystems are
  just mounted.
* An LV with `size`/`extents` is created if missing. If you later raise
  `size`, it is grown (with `--resizefs`). Shrinking is refused.
* An LV **without** `size`/`extents` must already exist; it is only mounted.
  Use this for disks you set up elsewhere.
* Percentage LVs (`extents: 100%FREE`) are created after all fixed-size LVs.

Nothing is ever removed: dropping an entry from pillar leaves the disk,
crypttab and fstab entries as they are.

## Layout

```
luks_lvm/
  init.sls          includes everything below
  packages.sls      cryptsetup, systemd-cryptsetup, lvm2 + mkfs tools in use
  luks.sls          key files, luksFormat (guarded), /etc/crypttab, unlock
  lvm.sls           PV (guarded), VG, activation, LVs
  filesystems.sls   mkfs (guarded), /etc/fstab + mount, systemd daemon-reload
  map.jinja         merges defaults + pillar, validates, normalises
  defaults.yaml     defaults
pillar.example
```

## Usage

1. Put the `luks_lvm` directory in your `file_roots` (or serve it via gitfs).
2. Write pillar based on `pillar.example`. Get disk IDs with
   `ls -l /dev/disk/by-id/` and pick the ones that contain the serial number.
3. Dry run, then apply:

   ```sh
   salt 'host' state.apply luks_lvm test=True
   salt 'host' state.apply luks_lvm
   ```

Individual layers can be applied on their own (`luks_lvm.luks`,
`luks_lvm.lvm`, `luks_lvm.filesystems`); each includes what it depends on.

## Pillar reference

Global (all optional, see `defaults.yaml`): `keydir`, `luks_format_opts`,
`crypttab_opts`, `mount_opts`, `fs`, `resizefs`, `mkfs_opts` (per fs type),
`pkgs`, `fs_pkgs`.

`luks_lvm:devices:<name>` – one per disk; `<name>` becomes `/dev/mapper/<name>`
and the crypttab name.

| Key                | Required | Meaning                                                                     |
|--------------------|----------|-----------------------------------------------------------------------------|
| `disk`             | yes      | `/dev/disk/by-id/...` path (other paths are rejected)                       |
| `key`              | one of   | Secret; written to `<keydir>/<name>.key` (0400, no trailing newline)        |
| `keyfile`          | one of   | Existing key file on the minion (or the path to write `key` to)             |
| `vg`               | –        | Use the container as an LVM PV in this VG                                   |
| `mountpoint`       | –        | Filesystem directly in the container (no LVM). Excludes `vg`                |
| `fs`, `opts`, `mkfs_opts` | – | For `mountpoint` devices                                                    |
| `crypttab`         | –        | `false` to not write /etc/crypttab (default `true`)                         |
| `crypttab_opts`    | –        | Per-device override; `discard` also enables `--allow-discards` on unlock    |
| `luks_format_opts` | –        | Per-device override for `cryptsetup luksFormat`                            |
| `open_opts`        | –        | Extra `cryptsetup open` options                                             |

`luks_lvm:vgs:<vg>:lvs:<lv>`:

| Key                | Meaning                                                              |
|--------------------|----------------------------------------------------------------------|
| `size` / `extents` | LV size (`200G`) or extents (`100%FREE`). Omit for existing LVs      |
| `fs`               | Filesystem type (default `ext4`). **Set the real type for existing data** |
| `mountpoint`       | Where to mount. Without `fs` and `mountpoint` the LV stays raw       |
| `opts`             | fstab options (default `defaults,nofail`)                            |
| `mkfs_opts`        | Extra mkfs options                                                   |
| `resizefs`         | Grow the fs with the LV (default `true`; set `false` for btrfs)      |

Pillar mistakes (non-by-id path, `vg` together with `mountpoint`, missing
key, VG with no device, `size` together with `extents`, duplicate
mountpoint) stop rendering with a message before anything runs.

## Debian trixie notes

* Salt is not in the Debian archive; install it from the Salt Project
  repository (packages.broadcom.com, `stable` suite). The formula only uses
  states that are still in Salt core in 3008 (`file`, `cmd`, `pkg`, `lvm`,
  `mount`); `/etc/crypttab` is edited with `file.replace` because the
  `cryptdev` state was removed from core in 3008. Only lines whose first
  field is one of the pillar's device names are touched.
* On trixie the crypttab generator ships in the separate
  **`systemd-cryptsetup`** package. Without it `/etc/crypttab` is silently
  ignored at boot, so the formula installs it.
* crypttab and fstab entries get `nofail` by default, so a missing or
  locked data disk does not drop the machine into emergency mode.
  `systemctl daemon-reload` runs whenever either file changes.
* These are data disks, so no `update-initramfs` is needed.

## Security notes

* The key file lives on the root filesystem so the disks unlock at boot.
  That is only meaningful if root itself is encrypted (or otherwise
  protected).
* Keep `key` out of plain-text pillar: use the GPG renderer or another
  secrets backend. The key is read via `contents_pillar` and diff output is
  disabled, so it does not appear in rendered SLS or state output.
* Because the key file has no trailing newline, the same string also works
  as a typed passphrase (`cryptsetup open` without `--key-file`).
* Consider adding a second, offline recovery passphrase per disk:
  `cryptsetup luksAddKey --key-file <keyfile> <disk>`.

## Caveats

* `test=True` cannot look inside containers that are not unlocked yet, so
  the dry run reports PV/VG/LV creation for existing disks that will in fact
  just be unlocked and mounted. A disk that would be refused shows up as
  "would have been executed" instead of failing.
* `fs` must match the existing filesystem on disks with data, or the mount
  fails.
