#!/bin/sh

## runs as partman/early_command: after disk detection, before partman-auto.
## partman-auto/disk comes from the kernel command line as
## /dev/disk/by-id/<id> (di_disk_<node> in menu/trixie.ipxe). The id names one
## physical disk (model + serial, WWN, ...), so the install can't land on the
## wrong disk when the kernel numbers the disks differently (sda/sdb).
## partman only knows kernel names (/dev/sda) and does not follow the link, so
## the link is resolved here and partman-auto/disk is set to the kernel name.
## If the id is missing or names no disk on this machine, show an error screen
## that lists the disk ids found, and clear partman-auto/method, so partman
## does not pick a disk and partition it on its own.

. /usr/share/debconf/confmodule

byid=/dev/disk/by-id

## put some logging in place
echo "Start partitioning.disk.sh" >> /var/log/syslog

## make sure udev has created all /dev/disk/by-id links
udevadm settle --timeout=10 >/dev/null 2>&1 || true

## is $1 a whole disk the installer can partition?
is_disk () {
  for d in $(list-devices disk); do
    [ "$d" = "$1" ] && return 0
  done
  return 1
}

## one entry per disk: "/dev/sda (500 GB): ata-Samsung_SSD_..._S3Z1NB0K123456 wwn-0x5002..."
list_disk_ids () {
  for d in $(list-devices disk); do
    ids=""
    for link in "$byid"/*; do
      [ -L "$link" ] || continue
      case "$link" in *-part[0-9]*) continue ;; esac
      [ "$(readlink -f "$link")" = "$d" ] && ids="$ids ${link##*/}"
    done
    size=$(awk '{ printf "%.0f GB", $1 * 512 / 1000000000 }' "/sys/block/${d#/dev/}/size" 2>/dev/null)
    echo "$d (${size:-unknown size}):${ids:- no id}"
  done
}

db_get partman-auto/disk
disk="$RET"
id="${disk#"$byid"/}"

if [ -z "$id" ]; then
  error="No install disk was passed (partman-auto/disk is empty). Set di_disk_<node> for this host in menu/trixie.ipxe to the disk's /dev/disk/by-id name."
elif [ "$id" = "$disk" ]; then
  error="partman-auto/disk is $disk, but it has to be a $byid/<id> path. Set di_disk_<node> for this host in menu/trixie.ipxe to the disk's /dev/disk/by-id name."
elif [ ! -e "$disk" ]; then
  error="There is no disk with the id $id on this machine. Check di_disk_<node> for this host in menu/trixie.ipxe."
else
  dev=$(readlink -f "$disk")
  if is_disk "$dev"; then
    echo "partitioning.disk.sh: installing to $dev ($disk)" >> /var/log/syslog
    db_set partman-auto/disk "$dev"
    exit 0
  fi
  error="The id $id points to $dev, which is not a whole disk (a partition, CD drive, ...). Use the id of the disk itself."
fi

disks=$(list_disk_ids)
{
  echo "partitioning.disk.sh: $error"
  echo "partitioning.disk.sh: disks found:"
  echo "${disks:-none}"
} >> /var/log/syslog

cat > /tmp/partitioning.disk.templates <<'EOF'
Template: partitioning/disk_error
Type: error
Description: No usable install disk
 ${ERROR}
 .
 Disks found: ${DISKS}
 .
 Automatic partitioning has been stopped and no disk was changed.
EOF
db_x_loadtemplatefile /tmp/partitioning.disk.templates d-i
db_subst partitioning/disk_error ERROR "$error"
## debconf values are single lines
db_subst partitioning/disk_error DISKS "$(echo "${disks:-none}" | sed '$!s/$/;/' | tr '\n' ' ')"
db_fset partitioning/disk_error seen false
db_input critical partitioning/disk_error || true
db_go || true

## without a method partman-auto does not partition anything by itself
db_set partman-auto/method ""
exit 0
