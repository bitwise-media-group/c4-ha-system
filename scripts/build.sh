#!/usr/bin/env sh
# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Builds every driver in drivers/ into dist/<name>.c4z.
#
# A .c4z is a zip with driver.xml at the root. Shared modules from lib/ are
# vendored into each driver as ha/, and the Control4 integer version is
# stamped from version.txt (semver major*10000 + minor*100 + patch) so all
# drivers in the monorepo version together.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
dist="$root/dist"

semver=$(tr -d ' \n' < "$root/version.txt")
major=${semver%%.*}
rest=${semver#*.}
minor=${rest%%.*}
patch=${rest#*.}
c4ver=$((major * 10000 + minor * 100 + patch))

echo "building version $semver (c4z version $c4ver)"
mkdir -p "$dist"

for driver_dir in "$root"/drivers/*/; do
    name=$(basename "$driver_dir")
    stage="$dist/.stage-$name"
    rm -rf "$stage"
    mkdir -p "$stage"

    cp "$driver_dir/driver.lua" "$stage/"
    [ -d "$driver_dir/www" ] && cp -R "$driver_dir/www" "$stage/www"

    # Shared library -> ha/ (require 'ha.<module>')
    mkdir -p "$stage/ha"
    cp "$root"/lib/ha/*.lua "$stage/ha/"

    # Only the gateway talks to the network: it gets the websocket module
    # and the CA roots for TLS peer verification.
    if [ "$name" = "ha-gateway" ]; then
        mkdir -p "$stage/certs"
        cp "$root"/certs/*.pem "$stage/certs/"
    else
        rm -f "$stage/ha/websocket.lua"
    fi

    # Stamp the shared version into driver.xml.
    sed "s|<version>[^<]*</version>|<version>$c4ver</version>|" \
        "$driver_dir/driver.xml" > "$stage/driver.xml"

    if command -v xmllint >/dev/null 2>&1; then
        xmllint --noout "$stage/driver.xml"
    fi

    rm -f "$dist/$name.c4z"
    (cd "$stage" && zip -q -r -X "$dist/$name.c4z" .)
    rm -rf "$stage"
    echo "  dist/$name.c4z"
done

echo "done"
