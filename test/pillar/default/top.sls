# Test pillar for scripts/test.sh (suite "default").
#
# acme_sh, luks_lvm, nm_connections and quadlets are symlinks to the
# formula's pillar.example, so the examples are rendered as well. No
# ignore_missing here: a file listed below that doesn't exist fails the run.
base:
  '*':
    - acme_sh
    - local_grains
    - luks_lvm
    - nm_connections
    - quadlets
    - restic
