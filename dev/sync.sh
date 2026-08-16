#!/usr/bin/env bash
# Dev loop: copy this repo into the live Omarchy plugins dir and validate it.
#
# Quattro forbids symlinked plugin dirs, so the only way to iterate is to
# copy the tree on every change; the shell's inotify watcher then live-reloads
# whatever changed. Re-run this script after each edit (or wrap it in your own
# watch loop) -- it is not itself a watcher.
#
# Usage: dev/sync.sh

set -euo pipefail

PLUGIN_ID="joegeary.on-air"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${HOME}/.config/omarchy/plugins/${PLUGIN_ID}"

mkdir -p "${TARGET}"

# -a preserves the exec bit on bin/on-air; --delete keeps the target from
# accumulating stale files removed here; dev/ and repo metadata never belong
# in the installed plugin.
rsync -a --delete \
  --exclude .git \
  --exclude .spec \
  --exclude dev \
  "${REPO_ROOT}/" "${TARGET}/"

omarchy plugin validate "${TARGET}"
