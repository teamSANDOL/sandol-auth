# 루트 프로젝트에서 sandol-auth로 이관 (같은 서버)

Keycloak 스택을 루트 compose(`tuk_sandol_team`)에서 이 레포의 독립 프로젝트로 옮기는 절차입니다. 볼륨은 그대로 두고 컨테이너만 바꾸므로 데이터는 이동하지 않습니다.
서버 경로 예: 루트 `~/tuk_sandol_team`, 이 레포 `~/sandol-auth`.

## 사전 준비

1. 루트 레포에서 이 이관이 반영된 커밋(Keycloak 서비스가 제거된 compose)을 받아 둡니다. 아직 `up` 하지 않습니다.
2. 이 레포를 clone하고 서브모듈을 초기화합니다(README 참고).
3. `.env`를 만듭니다. 루트 `.env`에서 `KC_DB_USERNAME`, `KC_DB_PASSWORD`, `KEYCLOAK_ADMIN_USERNAME`, `KEYCLOAK_ADMIN_PASSWORD`, `PG_EXPORTER_PASSWORD`, `SANDOL_DATA_DIR`, `BACKUP_KEEP`를 같은 값으로 복사하고 `KC_PUBLIC_URL=https://<SERVICE_DOMAIN>/auth`를 추가합니다. `COMPOSE_PROJECT_NAME`은 복사하지 않습니다.
4. 이름을 확인해 `.env`에 반영합니다: `docker volume ls | grep keycloak`(`KEYCLOAK_DB_VOLUME`, `KEYCLOAK_DATA_VOLUME`), `docker network ls | grep sandol`(`SANDOL_NETWORK_NAME`).
5. `sandol-auth-relay/.env`를 루트의 같은 파일에서 복사합니다.
   `.env`에 `COMPOSE_FILE=docker-compose.yml:docker-compose.colocated.yml`(`.env.example` 기본값)이 있는지 확인합니다. 없으면 평범한 `docker compose up -d`가 오버라이드 없이 떠서 keycloak·auth-relay가 루트 네트워크에서 빠집니다. 새 서버 단독 기동 시에는 이 줄을 제거합니다.
6. 전환 전 기준값을 기록합니다: realm 목록, 사용자 수(`select count(*) from user_entity`), issuer(`/auth/realms/Sandori/.well-known/openid-configuration`의 `issuer`). 개인정보는 기록하지 않고 개수만 봅니다.

```bash
docker compose -f docker-compose.yml -f docker-compose.colocated.yml config -q   # 이 레포에서. 오류 없어야 함
```

## 전환 (순서 중요)

> 순서 원칙: **sandol-auth가 healthy가 된 뒤에 루트를 `up`합니다.** meal-service는 기동 시 Keycloak에서 서비스 계정을 확인하고 실패하면 종료하며, gateway가 meal-service healthy를 기다리므로 루트 `up`이 중단됩니다.

1. **덤프**: 루트 변경을 적용하기 전에 Keycloak DB를 덤프합니다.
   ```bash
   set -euo pipefail
   : "${SANDOL_DATA_DIR:?SANDOL_DATA_DIR 필요}"
   DEST="$SANDOL_DATA_DIR/backups-auth/pre-split"
   mkdir -p "$DEST"
   docker exec keycloak-db sh -c 'pg_dump -U "$POSTGRES_USER" -d keycloak -Fc -f /tmp/pre-split.dump'
   docker cp keycloak-db:/tmp/pre-split.dump "$DEST/keycloak.dump"
   docker exec keycloak-db rm /tmp/pre-split.dump
   # 검증: 목차를 읽을 수 있고 크기가 0이 아니어야 한다
   docker run --rm -v "$DEST:/b:ro" postgres:16-alpine pg_restore -l /b/keycloak.dump | wc -l
   test -s "$DEST/keycloak.dump" && ls -l "$DEST/keycloak.dump"
   ```
   실패하면 다음 단계로 넘어가지 않습니다. 롤백에서 쓰는 파일도 이 경로(`$SANDOL_DATA_DIR/backups-auth/pre-split/keycloak.dump`)입니다.
2. **루트의 Keycloak 컨테이너 정지·삭제**(볼륨 유지, `-v` 금지). 변경 적용 전의 루트 compose(이전 커밋)로 실행합니다.
   ```bash
   cd ~/tuk_sandol_team
   docker compose stop keycloak auth-relay postgres-exporter-keycloak keycloak-db
   docker compose rm -f keycloak auth-relay postgres-exporter-keycloak keycloak-db
   docker volume ls | grep keycloak     # 두 볼륨이 남아 있어야 함
   ```
3. **sandol-auth를 colocated로 기동**: 컨테이너 이름이 같아 2단계 전에는 충돌합니다. Keycloak이 healthy가 될 때까지 약 1~2분 걸립니다(`db-backup`이 먼저 `keycloak.dump`를 만듭니다).
   ```bash
   cd ~/sandol-auth
   docker compose -f docker-compose.yml -f docker-compose.colocated.yml up -d
   ```
4. **루트 나머지 서비스 재기동**: 루트 변경(Keycloak 서비스·`depends_on` 제거)이 반영된 compose로 올립니다.
   ```bash
   cd ~/tuk_sandol_team
   git pull && git submodule update --init
   docker compose up -d
   ```
5. **확인**
   - 볼륨: `docker inspect keycloak --format '{{range .Mounts}}{{.Name}} {{end}}'`가 기존 볼륨 이름. realm `Sandori`, 사용자 수가 6단계 기준값과 같음.
   - issuer가 기준값과 같음(공개 경로 `/auth/realms/Sandori/.well-known/openid-configuration`).
   - 내부 경로: static-info·meal-service 컨테이너에서 `http://keycloak:8080/auth/realms/Sandori/protocol/openid-connect/certs` 요청 성공.
   - gateway `/relay/health` 200, kakao-bot 컨테이너에서 `http://auth-relay:8000/relay/health` 200.
   - 백업: `$SANDOL_DATA_DIR/backups-auth/<타임스탬프>/keycloak.dump` 생성, `sandol-auth-db-backup` 컨테이너 `Exited (0)`.
   - Prometheus에서 `up{db="keycloak"}` = 1.

## 롤백

문제가 있으면 sandol-auth를 내리고 루트의 이전 compose로 되돌립니다. 볼륨은 그대로이므로 데이터 손실이 없습니다.

```bash
cd ~/sandol-auth
docker compose -f docker-compose.yml -f docker-compose.colocated.yml down      # -v 금지
cd ~/tuk_sandol_team
git checkout <이관 이전 커밋>              # Keycloak 서비스가 있는 docker-compose.yml
git submodule update --init
docker compose up -d
```

이후 위 5단계 확인 항목을 같은 방식으로 확인합니다. DB가 손상된 경우에만 `$SANDOL_DATA_DIR/backups-auth/pre-split/keycloak.dump`로 복원합니다(`pg_restore --clean --if-exists`).

## 알아둘 점

- `docker compose up`은 `db-backup`을 매번 다시 실행해 덤프를 한 벌 더 만듭니다(보관 개수 초과분은 삭제).
- gateway는 이름으로 keycloak·auth-relay를 찾습니다. 3단계에서 컨테이너가 새로 만들어져도 gateway 재시작 없이 응답했습니다(테스트 서버).
- 루트 compose에서 볼륨 정의를 지워도 실제 볼륨은 삭제되지 않습니다(테스트 서버에서 전환 후에도 볼륨 유지 확인). sandol-auth에서 `down -v`는 하지 않습니다.
- `prometheus.yaml`의 `postgres-exporter-keycloak:9187`은 colocated에서 `sandol_network`로 풀립니다. Keycloak을 다른 서버로 옮기면 target을 바꿉니다.
- 새 서버로 옮길 때: 이 레포만 clone하고 단독 기동하되, 기존 데이터는 `pre-split` 덤프(또는 `docker-compose.auth-restore.yml` import)로 복원한 뒤 gateway upstream을 새 주소로 바꿉니다(범위 밖 작업).
