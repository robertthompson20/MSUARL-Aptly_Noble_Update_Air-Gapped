#!/usr/bin/env bash
set -euo pipefail

CONFIG="/etc/aptly/aptly.conf"

# Noble base: full components for install-time packages
aptly -config="$CONFIG" \
  -architectures=amd64 \
  mirror create ubuntu-noble \
  http://archive.ubuntu.com/ubuntu \
  noble \
  main restricted universe multiverse

aptly -config="$CONFIG" mirror update ubuntu-noble

# Noble-updates: Canonical-supported only (main + restricted)
aptly -config="$CONFIG" \
  -architectures=amd64 \
  mirror create ubuntu-noble-updates \
  http://archive.ubuntu.com/ubuntu \
  noble-updates \
  main restricted

aptly -config="$CONFIG" mirror update ubuntu-noble-updates

# Noble-security: Canonical-supported only (main + restricted)
aptly -config="$CONFIG" \
  -architectures=amd64 \
  mirror create ubuntu-noble-security \
  http://security.ubuntu.com/ubuntu \
  noble-security \
  main restricted

aptly -config="$CONFIG" mirror update ubuntu-noble-security
