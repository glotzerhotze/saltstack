# salt/packages/backports_kernel.sls

backports_kernel:
  pkg.latest:
  - pkgs:
    - linux-image-amd64
    # - linux-headers-amd64   # only if you build DKMS modules
  - fromrepo: trixie-backports
  - require:
    - sls: apt.repositories