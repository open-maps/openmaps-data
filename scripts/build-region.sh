#!/usr/bin/env bash
# Builds one region's routing graph and map file with its outline from the plan.
# Usage: build-region.sh PLAN_DIR SLUG EXTRACT_DIR OUT_DIR
set -euo pipefail
plan=$1
slug=$2
extracts=$3
out=$4
here=$(dirname "$0")
# shellcheck source=scripts/common.sh
. "$here/common.sh"

entry=$(jq --arg slug "$slug" '.regions[] | select(.slug == $slug)' "$plan/regions.json")
planet=$(jq -r '.planet' "$plan/regions.json")
map_version=$(jq -r '.mapVersion' "$plan/regions.json")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

inputs=()
while read -r url; do
  inputs+=("$extracts/$(extract_name "$url")")
done < <(jq -r '.extracts[]' <<<"$entry")
osm_date=$(osmium fileinfo -g header.option.osmosis_replication_timestamp "${inputs[0]}" || true)

# Neighbouring extracts overlap at borders. Valhalla aborts on the duplicates, so they are merged into one file first.
osmium merge --overwrite -o "$work/merged.osm.pbf" "${inputs[@]}"
osmium extract --overwrite -s smart -p "$plan/outlines/$slug.routing.geojson" -o "$work/input.osm.pbf" "$work/merged.osm.pbf"
rm "$work/merged.osm.pbf"

valhalla_build_config \
  --mjolnir-tile-dir "$work/tiles" \
  --mjolnir-tile-extract "$work/$slug.valhalla.tar" \
  --mjolnir-admin "$work/admins.sqlite" \
  --mjolnir-timezone "$plan/timezones.sqlite" \
  --mjolnir-concurrency "$(nproc)" >"$work/valhalla.json"
valhalla_build_admins -c "$work/valhalla.json" "$work/input.osm.pbf"
valhalla_build_tiles -c "$work/valhalla.json" "$work/input.osm.pbf"
valhalla_build_extract -c "$work/valhalla.json" -O
rm -rf "$work/tiles" "$work/input.osm.pbf"
zstd -19 --long=27 -T0 --rm -q "$work/$slug.valhalla.tar" -o "$out/$slug.valhalla.tar.zst"

# The server allows downloads like this, and four parallel requests keep the load modest.
pmtiles extract "$planet" "$out/$slug.pmtiles" \
  --region="$plan/outlines/$slug.map.geojson" --minzoom=8 --maxzoom=14 --download-threads=4

file_info() {
  jq -n --arg name "$(basename "$1")" --argjson size "$(stat -c %s "$1")" --arg sha256 "$(sha256sum "$1" | cut -d' ' -f1)" \
    '{name: $name, size: $size, sha256: $sha256}'
}
jq -n --argjson entry "$entry" --arg osmDate "$osm_date" --arg mapVersion "$map_version" \
  --argjson map "$(file_info "$out/$slug.pmtiles")" --argjson routing "$(file_info "$out/$slug.valhalla.tar.zst")" \
  '$entry | del(.extracts) | . + {osmDate: $osmDate, mapVersion: $mapVersion, map: $map, routing: $routing}' >"$out/$slug.json"
