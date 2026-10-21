#!/bin/bash

set -e
set -o pipefail

## install backports kernel
DEBIAN_FRONTEND=noninteractive apt-get install -y -t $(lsb_release -cs)-backports linux-image-amd64 linux-headers-amd64;
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y