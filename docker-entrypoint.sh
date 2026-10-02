#!/bin/sh
set -eu

if [ "$#" -eq 0 ]; then
    set -- /etc/zigveil/config.json
fi
case "$1" in
    --*) exec /usr/local/bin/zigveil "$@" ;;
esac
if [ ! -f "$1" ] || [ ! -r "$1" ]; then
    echo "zigveil: mount a readable config.json at $1" >&2
    exit 1
fi
exec /usr/local/bin/zigveil "$@"
