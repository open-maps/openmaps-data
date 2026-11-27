#!/usr/bin/env bash
# Cuts the whole world at low zoom from the planet file, shown where no region is downloaded.
# Usage: overview.sh PLAN_DIR OUT_DIR
set -euo pipefail
plan=$1
out=$2
mkdir -p "$out"
planet=$(jq -r '.planet' "$plan/regions.json")
pmtiles extract "$planet" "$out/world.pmtiles" --maxzoom=7 --download-threads=4
jq -n --arg mapVersion "$(jq -r '.mapVersion' "$plan/regions.json")" --argjson size "$(stat -c %s "$out/world.pmtiles")" \
  --arg sha256 "$(sha256sum "$out/world.pmtiles" | cut -d' ' -f1)" \
  '{mapVersion: $mapVersion, map: {name: "world.pmtiles", size: $size, sha256: $sha256}}' >"$out/world.json"
