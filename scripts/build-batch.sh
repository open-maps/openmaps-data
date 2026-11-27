#!/usr/bin/env bash
# Builds every region of one batch and uploads each to its continent's draft release as soon as it is done.
# Usage: build-batch.sh PLAN_DIR BATCH_ID STAGING_TAG
set -euo pipefail
plan=$1
batch=$2
staging=$3
here=$(dirname "$0")
# shellcheck source=scripts/common.sh
. "$here/common.sh"

date=$(jq -r '.date' "$plan/regions.json")
extracts=$(mktemp -d)
out=$(mktemp -d)
trap 'rm -rf "$extracts" "$out"' EXIT

jq -r --arg batch "$batch" '.batches[] | select(.id == $batch) | .extracts[]' "$plan/regions.json" | while read -r url; do
  gh release download "$staging" --pattern "$(extract_name "$url")" --dir "$extracts"
done

failed=0
for slug in $(jq -r --arg batch "$batch" '.batches[] | select(.id == $batch) | .regions[]' "$plan/regions.json"); do
  continent=$(jq -r --arg slug "$slug" '.regions[] | select(.slug == $slug) | .continent' "$plan/regions.json")
  if "$here/build-region.sh" "$plan" "$slug" "$extracts" "$out"; then
    gh release upload "$continent-$date" "$out/$slug.pmtiles" "$out/$slug.valhalla.tar.zst" "$out/$slug.json" --clobber
  else
    echo "::error::Building $slug failed"
    failed=1
  fi
  rm -f "$out"/*
done
exit "$failed"
