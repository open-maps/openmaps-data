#!/usr/bin/env bash
# Downloads the extracts of one fetch group once, keeps what routing needs and uploads them to the staging release.
# Usage: fetch.sh PLAN_DIR GROUP_ID STAGING_TAG
set -euo pipefail
plan=$1
group=$2
staging=$3
here=$(dirname "$0")
# shellcheck source=scripts/common.sh
. "$here/common.sh"

# Ways and relations Valhalla reads for cars, bikes and walking, plus the boundaries it takes country rules from.
# Nodes of kept ways come along with their tags, such as barriers and signals.
# shellcheck disable=SC2054
routing_filter=(
  w/highway
  w/route=ferry,shuttle_train
  w/railway=platform
  w/public_transport=platform
  w/man_made=pier
  r/type=restriction
  r/boundary=administrative
  r/route=bicycle,mtb,hiking,foot,ferry
)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Chained, as errexit does not apply inside the if that calls this.
fetch_one() {
  local name
  name=$(extract_name "$1")
  download "$1" "$work/raw.osm.pbf" &&
    osmium tags-filter --overwrite -o "$work/$name" "$work/raw.osm.pbf" "${routing_filter[@]}" &&
    rm "$work/raw.osm.pbf" &&
    gh release upload "$staging" "$work/$name" --clobber &&
    rm "$work/$name"
}

# One failed extract must not keep the others of the group from being fetched.
failed=0
while read -r url; do
  if ! (fetch_one "$url"); then
    echo "::error::Fetching $url failed"
    failed=1
  fi
done < <(jq -r --arg group "$group" '.fetches[] | select(.id == $group) | .extracts[]' "$plan/regions.json")
exit "$failed"
