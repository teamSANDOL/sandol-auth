#!/usr/bin/env bash
# keycloak-db에 postgres-exporter용 read-only 계정(sandol_exporter)을 만든다. 여러 번 돌려도 된다.
#   PG_EXPORTER_PASSWORD=... ./scripts/create-pg-exporter-role.sh   (또는 .env에 두고 실행)
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PASSWORD="${PG_EXPORTER_PASSWORD:-$(grep -E '^PG_EXPORTER_PASSWORD=' .env 2>/dev/null | head -1 | cut -d= -f2- || true)}"
[ -n "$PASSWORD" ] || { echo "PG_EXPORTER_PASSWORD가 없다(.env 또는 환경변수)" >&2; exit 1; }
KC_USER="${KC_DB_USERNAME:-$(grep -E '^KC_DB_USERNAME=' .env | head -1 | cut -d= -f2-)}"
docker exec -i keycloak-db psql -v ON_ERROR_STOP=1 -U "$KC_USER" -d keycloak -v pw="$PASSWORD" >/dev/null <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'sandol_exporter') THEN
    CREATE ROLE sandol_exporter LOGIN;
  END IF;
END
$$;
ALTER ROLE sandol_exporter WITH PASSWORD :'pw';
GRANT pg_monitor TO sandol_exporter;
GRANT CONNECT ON DATABASE keycloak TO sandol_exporter;
SQL
echo "완료 keycloak-db"
