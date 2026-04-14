#!/usr/bin/env bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/test_apps/rails8_smoke"
DEPLOY_ROOT="/tmp/mira_rails8_smoke"
PID_FILE="$DEPLOY_ROOT/shared/tmp/pids/puma.pid"
SMOKE_URL="http://127.0.0.1:3101/up"

wait_for_http_200() {
	local url="$1"
	local retries=30
	local i

	for i in $(seq 1 "$retries"); do
		if curl -fsS "$url" >/dev/null; then
			return 0
		fi
		sleep 1
	done

	echo "[smoke] ERROR: health check failed for $url"
	return 1
}

source "$HOME/.rvm/scripts/rvm"
rvm use 4.0.2 >/dev/null

cd "$ROOT_DIR"
cd "$APP_DIR"

if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
	kill -TERM "$(cat "$PID_FILE")" || true
	sleep 1
fi

if lsof -tiTCP:3101 -sTCP:LISTEN >/dev/null 2>&1; then
	lsof -tiTCP:3101 -sTCP:LISTEN | xargs kill -TERM || true
	sleep 1
fi

rm -rf "$DEPLOY_ROOT"

"$ROOT_DIR/bin/mira" setup
"$ROOT_DIR/bin/mira" deploy
"$ROOT_DIR/bin/mira" puma:status
wait_for_http_200 "$SMOKE_URL"

first_release="$(readlink "$DEPLOY_ROOT/current")"
sleep 1

"$ROOT_DIR/bin/mira" deploy
second_release="$(readlink "$DEPLOY_ROOT/current")"

if [[ "$first_release" == "$second_release" ]]; then
	echo "[smoke] ERROR: second deploy did not create a new release"
	exit 1
fi

"$ROOT_DIR/bin/mira" rollback
rollback_release="$(readlink "$DEPLOY_ROOT/current")"

if [[ "$rollback_release" != "$first_release" ]]; then
	echo "[smoke] ERROR: rollback did not switch to previous release"
	echo "[smoke] expected: $first_release"
	echo "[smoke] actual:   $rollback_release"
	exit 1
fi

"$ROOT_DIR/bin/mira" puma:status
wait_for_http_200 "$SMOKE_URL"

echo "[smoke] ok"
