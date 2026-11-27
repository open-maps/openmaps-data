#!/usr/bin/env bash
# Builds the car routing graph of open-road-incidents and an empty live traffic extract for it, and publishes both in parts.
# Usage: build-ori.sh PLAN_DIR STAGING_TAG RELEASE_TAG
set -euo pipefail
plan=$1
staging=$2
release=$3
here=$(dirname "$0")
# shellcheck source=scripts/common.sh
. "$here/common.sh"

# The same roads open-road-incidents keeps. Closures and slowdowns only change car routes.
# shellcheck disable=SC2054
roads_filter=(
  w/highway=motorway,motorway_link,trunk,trunk_link,primary,primary_link,secondary,secondary_link,tertiary,tertiary_link
  w/highway=unclassified,residential,living_street,service,road
  w/route=ferry
  r/type=restriction
)
# GitHub refuses release files of 2 GiB or more.
part_size=1900M

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/roads" "$work/out"
jq -r '.ori[]' "$plan/regions.json" | while read -r url; do
  name=$(extract_name "$url")
  gh release download "$staging" --pattern "$name" --dir "$work"
  osmium tags-filter --overwrite -o "$work/roads/$name" "$work/$name" "${roads_filter[@]}"
  rm "$work/$name"
done

# Neighbouring extracts overlap at borders. Valhalla aborts on the duplicates, so they are merged into one file first.
osmium merge --overwrite -o "$work/roads.osm.pbf" "$work"/roads/*.osm.pbf
rm -rf "$work/roads"
valhalla_build_config \
  --mjolnir-tile-dir "$work/tiles" \
  --mjolnir-tile-extract "$work/valhalla_tiles.tar" \
  --mjolnir-traffic-extract "$work/traffic.tar" \
  --mjolnir-concurrency "$(nproc)" \
  --mjolnir-admin "" \
  --mjolnir-timezone "" >"$work/valhalla.json"
valhalla_build_tiles -c "$work/valhalla.json" "$work/roads.osm.pbf"
rm "$work/roads.osm.pbf"
valhalla_build_extract -c "$work/valhalla.json" -t -O
rm -rf "$work/tiles"

files=()
for tar in valhalla_tiles traffic; do
  sha256=$(sha256sum "$work/$tar.tar" | cut -d' ' -f1)
  zstd -19 --long=27 -T0 --rm -q "$work/$tar.tar" -o "$work/$tar.tar.zst"
  split -b "$part_size" -d -a 2 "$work/$tar.tar.zst" "$work/out/$tar.tar.zst.part"
  rm "$work/$tar.tar.zst"
  files+=("$(jq -n --arg name "$tar.tar" --arg sha256 "$sha256" \
    --argjson parts "$(cd "$work/out" && find . -name "$tar.tar.zst.part*" -printf '%f\n' | sort | jq -R . | jq -s .)" \
    '{name: $name, sha256: $sha256, parts: $parts}')")
done
jq -n --arg date "$(jq -r .date "$plan/regions.json")" --argjson files "$(printf '%s\n' "${files[@]}" | jq -s .)" \
  '{date: $date, files: $files}' >"$work/out/ori.json"

gh release upload "$release" "$work"/out/* --clobber
gh release edit "$release" --draft=false --latest=false
