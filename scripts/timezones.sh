#!/usr/bin/env bash
# Builds the timezone database every region's routing graph is built with.
# Usage: timezones.sh PLAN_DIR
set -euo pipefail
plan=$(cd "$1" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
valhalla_build_timezones >"$plan/timezones.sqlite"
