# shellcheck shell=bash
# Shared by the build scripts. Sourced, not run.

user_agent="openmaps-data (https://github.com/open-maps/openmaps-data)"

# The file name of a Geofabrik extract once filtered to what routing needs.
extract_name() {
  local path=${1#*download.geofabrik.de/}
  path=${path%-latest.osm.pbf}
  echo "${path//\//_}.routing.osm.pbf"
}

download() {
  curl -fsSL --retry 5 --retry-delay 30 -A "$user_agent" -o "$2.part" "$1"
  mv "$2.part" "$2"
}
