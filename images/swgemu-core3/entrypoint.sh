#!/bin/bash
# Core3 entrypoint: write config-local.lua from the environment, prepare the database, wait for the client
# TRE files, then run the server with its console on a FIFO (see `console`) so SIGTERM can save before exit.
set -euo pipefail

BIN=/opt/swgemu/bin
RUN_DIR=/run/core3
CONSOLE=$RUN_DIR/console

: "${DBHOST:=mariadb}" "${DBPORT:=3306}" "${DBUSER:=swgemu}"
: "${DBPASS:?DBPASS must be set}" "${DBSECRET:?DBSECRET must be set}"
: "${GALAXY_ID:=2}" "${GALAXY_NAME:=Core3}" "${GALAXY_ADDRESS:=127.0.0.1}"
: "${AUTOREG:=0}" "${TREPATH:=/tre}" "${LOGIN_PORT:=44453}" "${PING_PORT:=44462}" "${ZONE_PORT:=44463}" "${STATUS_PORT:=44455}"
# swgemu.sql hard-codes the database name
DBNAME=swgemu

log() { echo "[entrypoint] $*"; }

# Lua string literal
lua_str() {
	local s=${1//\\/\\\\}
	s=${s//\"/\\\"}
	printf '"%s"' "$s"
}

export MYSQL_PWD=$DBPASS
db() { mariadb --host="$DBHOST" --port="$DBPORT" --user="$DBUSER" "$@"; }

mkdir -p /data/databases /data/navmeshes /data/log/admin /data/exports

cat > "$RUN_DIR/config-local.lua" <<EOF
-- Written by the container entrypoint at start; edit the Deployment env instead
Core3.DBHost = $(lua_str "$DBHOST")
Core3.DBPort = $DBPORT
Core3.DBName = $(lua_str "$DBNAME")
Core3.DBUser = $(lua_str "$DBUSER")
Core3.DBPass = $(lua_str "$DBPASS")
Core3.DBSecret = $(lua_str "$DBSECRET")
Core3.MantisHost = ""
Core3.TrePath = $(lua_str "$TREPATH")
Core3.ZoneGalaxyID = $GALAXY_ID
Core3.LoginPort = $LOGIN_PORT
Core3.PingPort = $PING_PORT
Core3.ZoneServerPort = $ZONE_PORT
Core3.StatusPort = $STATUS_PORT
Core3.AutoReg = $AUTOREG
Core3.ProgressMonitors = "false"
EOF
if [ -n "${CORE3_CONFIG_EXTRA:-}" ]; then
	printf '%s\n' "$CORE3_CONFIG_EXTRA" >> "$RUN_DIR/config-local.lua"
fi

until db -e 'SELECT 1' >/dev/null 2>&1; do
	log "waiting for the database at $DBHOST:$DBPORT"
	sleep 5
done

if [ -z "$(db -N -e "SHOW TABLES IN \`$DBNAME\` LIKE 'accounts'")" ]; then
	log "empty database, importing swgemu.sql"
	db < /opt/swgemu/sql/swgemu.sql
fi

# The login server hands clients this address for the zone server, so it must be reachable by players
db "$DBNAME" <<EOF
INSERT INTO galaxy (galaxy_id, name, address, port, pingport)
VALUES ($GALAXY_ID, '$GALAXY_NAME', '$GALAXY_ADDRESS', $ZONE_PORT, $PING_PORT)
ON DUPLICATE KEY UPDATE name = VALUES(name), address = VALUES(address), port = VALUES(port), pingport = VALUES(pingport);
EOF
log "galaxy $GALAXY_ID '$GALAXY_NAME' advertised at $GALAXY_ADDRESS:$ZONE_PORT"

# Every TreFiles entry in config.lua has to exist before Core3 can start
mapfile -t tre_files < <(sed -n '/TreFiles = {/,/}/p' "$BIN/conf/config.lua" | grep -oE '[A-Za-z0-9_]+\.tre')
while :; do
	missing=()
	for f in "${tre_files[@]}"; do
		[ -f "$TREPATH/$f" ] || missing+=("$f")
	done
	[ ${#missing[@]} -eq 0 ] && break
	log "missing ${#missing[@]} of ${#tre_files[@]} client TRE files in $TREPATH (e.g. ${missing[0]}); copy them in, see CLAUDE.md. Checking again in 30s"
	sleep 30
done

rm -f "$CONSOLE"
mkfifo -m 600 "$CONSOLE"
# Hold a writer open so Core3 never sees EOF on stdin
exec 3<>"$CONSOLE"

cd "$BIN"
./core3 <&3 &
pid=$!

# "shutdown 0" runs the shutdown task at once: final save, then exit
trap 'log "stopping: asking core3 to save and shut down"; echo "shutdown 0" >&3' TERM INT

status=0
while :; do
	wait "$pid" && status=0 || status=$?
	kill -0 "$pid" 2>/dev/null || break
done
log "core3 exited with status $status"
exit "$status"
