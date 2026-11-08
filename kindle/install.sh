#!/bin/sh
# install.sh -- copy the KUAL extension into place on a jailbroken Kindle.
#
# From kterm / ssh:
#   cd /mnt/us/awing && sh kindle/install.sh
# or copy this repo's autologin.sh and kindle/ onto the Kindle first.

set -e
HERE=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
ROOT=$(cd "$HERE/.." && pwd)
DST=/mnt/us/extensions/awing

mkdir -p "$DST"
cp "$ROOT/autologin.sh" "$HERE/control.sh" "$HERE/menu.json" "$HERE/config.xml" "$DST/"
chmod +x "$DST/autologin.sh" "$DST/control.sh"

echo "installed to $DST"
echo "KUAL -> Awing WiFi -> Login now"
