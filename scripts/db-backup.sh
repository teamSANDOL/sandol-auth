#!/bin/sh
# Keycloak DB를 pg_dump로 스냅샷한다. db-backup 서비스가 one-shot으로 실행하고,
# keycloak은 depends_on: service_completed_successfully 로 이 완료를 기다린다.
# non-zero로 끝나면 keycloak이 기동되지 않는다(fail-closed).
set -eu

OUT_ROOT="${BACKUP_OUT_DIR:-/backup}"
KEEP="${BACKUP_KEEP:-10}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="$OUT_ROOT/$STAMP"

mkdir -p "$DEST"

echo "[db-backup] pg_dump keycloak (keycloak@keycloak-db)"
PGPASSWORD="${KC_DB_PASSWORD:?KC_DB_PASSWORD 필요}" pg_dump -h keycloak-db \
    -U "${KC_DB_USERNAME:?KC_DB_USERNAME 필요}" -d keycloak -Fc -f "$DEST/keycloak.dump"

# 오래된 백업 정리. 실패해도 배포를 막지 않는다.
cd "$OUT_ROOT" && ls -1d */ 2>/dev/null | sort -r | tail -n "+$((KEEP + 1))" | while read -r old; do
    echo "[db-backup] 보존정책($KEEP) 초과 삭제: $old"
    rm -rf -- "$old" || true
done

echo "[db-backup] 완료 → $DEST"
ls -la "$DEST"
