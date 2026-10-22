#!/usr/bin/env bash
# yq.sh <directory>: installs yq at a pinned version, checked by its hash, for the plan (the runner
# image's own yq is not pinned).
set -euo pipefail
dir=${1:?usage: yq.sh <directory>}
curl -fsSL --retry 3 -o "$dir/yq" https://github.com/mikefarah/yq/releases/download/v4.47.1/yq_linux_amd64
echo "0fb28c6680193c41b364193d0c0fc4a03177aecde51cfc04d506b1517158c2fb  $dir/yq" | sha256sum -c --quiet
chmod +x "$dir/yq"
