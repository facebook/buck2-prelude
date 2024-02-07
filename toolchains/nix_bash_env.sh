#!/usr/bin/env bash
set -euo pipefail

cat > "$1" <<EOF
#!$BASH
export PATH='$PATH'

exec '$BASH' "\$@"
EOF

chmod +x "$1"
