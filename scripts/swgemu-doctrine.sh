#!/usr/bin/env bash
# swgemu-doctrine.sh — Load, show or pull back the hunting crew's doctrines on the running server (Phase 9b)
# The doctrine files are images/swgemu-core3/talk/doctrine/<first>.txt. "load" copies them into the core3 pod's data volume
# (/data/doctrine/base/), where the talk bridge picks them up within seconds and remakes each changed bot's tactics; the
# crew uses them from the next fight. No restart, no image build. Taught lines (said in game: "from now on...") live in
# /data/doctrine/taught/ and survive restarts; "pull" appends them to the repo's files for you to review and commit.
# Safe to rerun.
#
# Usage: bash scripts/swgemu-doctrine.sh load
#        bash scripts/swgemu-doctrine.sh show quillan      (the file, the taught lines and the tactics it made)
#        bash scripts/swgemu-doctrine.sh pull              (taught lines into the repo's files; then clears them in game)

set -euo pipefail

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

SRC="images/swgemu-core3/talk/doctrine"
DIR="/data/doctrine"
pod() { kubectl -n swgemu exec -i deploy/core3 -c talk -- "$@"; }
confirm() { read -r -p "$1 [y/N] " reply; [[ $reply == [yY]* ]]; }

cmd=${1:?usage: $0 load | show <first> | pull}

case $cmd in
load)
    ls "$SRC"/*.txt >/dev/null
    pod mkdir -p "$DIR/base"
    tar -C "$SRC" -cf - --exclude='*~' . | pod tar -C "$DIR/base" -xf -
    echo "Loaded: $(cd "$SRC" && ls *.txt | tr '\n' ' ')"
    echo "Waiting for the bridge to remake the tactics..."
    sleep 20
    kubectl -n swgemu logs deploy/core3 -c talk --since=60s | grep -i 'doctrine\|tactics' || echo "(no doctrine lines in the talk log yet; check: bash $0 show <first>)"
    ;;
show)
    first=${2:?usage: $0 show <first name, lower case>}
    first=$(tr '[:upper:]' '[:lower:]' <<<"$first")
    echo "=== $first: doctrine (server copy) ==="
    pod sh -c "cat $DIR/base/$first.txt 2>/dev/null || cat /opt/swgemu/talk/doctrine/$first.txt"
    echo "=== taught in game ==="
    pod sh -c "cat $DIR/taught/$first.txt 2>/dev/null || echo '(none)'"
    echo "=== tactics it made ==="
    pod sh -c "cat $DIR/tables/$first.json 2>/dev/null || echo '(none yet)'"
    echo
    ;;
pull)
    found=0
    for f in $(pod sh -c "ls $DIR/taught/ 2>/dev/null" || true); do
        first=${f%.txt}
        lines=$(pod cat "$DIR/taught/$f")
        [[ -n $lines ]] || continue
        found=1
        echo "=== $first ==="
        echo "$lines"
        # (crew.txt holds lessons for everyone: they go into every bot's file, as no bot reads a crew.txt in base/)
        if [[ $first == crew ]]; then
            targets=$(cd "$SRC" && ls *.txt | grep -vx 'crew.txt')
        else
            targets=$first.txt
        fi
        for t in $targets; do
            { echo; echo "# Taught in game, pulled $(date +%F):"; echo "$lines"; } >>"$SRC/$t"
        done
    done
    [[ $found == 1 ]] || { echo "Nothing taught in game."; exit 0; }
    echo
    echo "Appended to $SRC/. Review with: git diff $SRC"
    if confirm "Clear the taught lines on the server (they're in the files now; run load after you commit)?"; then
        pod sh -c "rm -f $DIR/taught/*.txt"
        echo "Cleared. Run: bash $0 load"
    fi
    ;;
*)
    echo "usage: $0 load | show <first> | pull" >&2
    exit 1
    ;;
esac
