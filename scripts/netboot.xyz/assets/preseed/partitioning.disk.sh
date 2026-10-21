#!/bin/sh

## runs as partman/early_command: after disk detection, before partman-auto.
## partman-auto/disk comes from the kernel command line (di_disk_<node> in
## menu/trixie.ipxe). If it is empty or names no existing disk, show an error
## screen and clear partman-auto/method, so partman does not pick a disk and
## partition it on its own.

. /usr/share/debconf/confmodule

## put some logging in place
echo "Start partitioning.disk.sh" >> /var/log/syslog

db_get partman-auto/disk
disk="$RET"

if [ -z "$disk" ] || [ "$disk" = /dev/ ]; then
  error="No install disk was passed (partman-auto/disk is empty). Set di_disk_<node> for this host in menu/trixie.ipxe."
elif [ ! -b "$disk" ]; then
  error="The install disk $disk does not exist on this machine. Check di_disk_<node> for this host in menu/trixie.ipxe. Disks found: $(list-devices disk | tr '\n' ' ')"
else
  echo "partitioning.disk.sh: installing to $disk" >> /var/log/syslog
  exit 0
fi

echo "partitioning.disk.sh: $error" >> /var/log/syslog

cat > /tmp/partitioning.disk.templates <<'EOF'
Template: partitioning/disk_error
Type: error
Description: No usable install disk
 ${ERROR}
 .
 Automatic partitioning has been stopped and no disk was changed.
EOF
db_x_loadtemplatefile /tmp/partitioning.disk.templates d-i
db_subst partitioning/disk_error ERROR "$error"
db_fset partitioning/disk_error seen false
db_input critical partitioning/disk_error || true
db_go || true

## without a method partman-auto does not partition anything by itself
db_set partman-auto/method ""
exit 0
