#!/bin/sh
# arrencada.command - macOS double-click launcher for arrencada.sh.
here=$(cd "$(dirname "$0")" && pwd)

has_repo=0
for a in "$@"; do
  case $a in
    --repo | --help | -h) has_repo=1 ;;
  esac
done

if [ "$has_repo" = 0 ]; then
  printf '[arrencada] Quin projecte vols preparar? (format ORG/NOM): '
  read -r repo
  set -- --repo "$repo" "$@"
fi

status=0
sh "$here/arrencada.sh" "$@" || status=$?

if [ "$status" -ne 0 ]; then
  printf '[arrencada] El procés ha acabat amb el codi %s. Prem Retorn per tancar.' "$status"
  read -r _
fi
exit "$status"
