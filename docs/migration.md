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
7. 운영 배포 전 확인: (a) 운영 kakao-bot `.env`의 `AUTH_RELAY_URL`이 내부 주소(`http://auth-relay:8000/relay` 또는 인증 서버 `http://<인증IP>:8000/relay`)이고 공개 도메인이 아닌지, (b) gateway 액세스 로그에 `/relay/issue_login_link` 외부 호출이 있었는지(`docker logs sandol-gateway | grep issue_login_link`). 외부 호출이 있으면 이 경로를 막는 루트 변경(TASK-186)을 배포하기 전에 호출자를 먼저 정리한다.
8. 점검 창 동안 메인 서버 kakao-bot `.env`에 `KC_TOKEN_PURGE_ENABLED=false`를 넣고 kakao-bot을 재시작합니다. issuer 불일치 등으로 `invalid_grant`가 나도 저장된 토큰이 지워지지 않아, 설정만 고치면 복구됩니다. 모든 확인을 마친 뒤 `true`로 되돌리고 다시 재시작합니다(전환·분리 각각, 마지막 단계에 포함).
9. 전환 전 refresh_token을 받아 둡니다(아래 "refresh_token 갱신 확인"의 1단계). 이 파일은 확인이 끝나면 삭제합니다.

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
   - 전환 전에 받아 둔 테스트 계정 refresh_token(offline·online 각각)으로 갱신 → 둘 다 HTTP 200, 새 access_token의 `iss`가 공개 issuer와 같음("refresh_token 갱신 확인" 2단계). 실패하면 kakao-bot `KC_TOKEN_PURGE_ENABLED=false` 상태에서 원인을 고친다.
6. **마무리**: 확인이 끝나면 kakao-bot `.env`의 `KC_TOKEN_PURGE_ENABLED`를 `true`로 되돌리고 kakao-bot을 재시작하며, 테스트 계정·client·토큰 파일을 지웁니다.

## 롤백

문제가 있으면 sandol-auth를 내리고 루트의 이전 compose로 되돌립니다. 볼륨은 그대로이므로 데이터 손실이 없습니다.

```bash
cd ~/sandol-auth
docker compose -f docker-compose.yml -f docker-compose.colocated.yml down      # -v 금지
cd ~/tuk_sandol_team
git checkout <이관 이전 커밋>              # Keycloak 서비스가 있는 docker-compose.yml. amqp healthcheck 수정(TASK-195)이 들어 있는 커밋이어야 한다(아래 주의)
git submodule update --init
docker compose up -d
```

**롤백 대상 커밋 주의(TASK-195)**: 이관 이전 compose의 amqp healthcheck(`rabbitmq-diagnostics` 3회 호출, interval 10s·timeout 5s·start_period 없음)는 호출마다 Erlang VM을 띄워 유휴에도 약 2초, 서버 부하가 높으면(keycloak·DB 기동 중 load 8 이상) 5초를 넘겨 timeout이 된다. 5회 연속이면 amqp가 unhealthy가 되고 `docker compose up -d`가 `dependency failed to start: container amqp is unhealthy`로 중단돼 gateway·auth-relay가 만들어지지 않는다(테스트 서버에서 부하를 주어 재현). 수정은 amqp healthcheck를 TCP 점검(5672·15692)으로 바꾼 커밋이며, 롤백 대상은 이를 포함한 main 기반 커밋이어야 한다. 그렇지 않은 커밋으로 롤백해 중단되면 `--no-deps` 없이 amqp가 healthy가 된 뒤 `docker compose up -d`를 한 번 더 실행하면 된다(멱등).

이후 위 5단계 확인 항목을 같은 방식으로 확인합니다. DB가 손상된 경우에만 `$SANDOL_DATA_DIR/backups-auth/pre-split/keycloak.dump`로 복원합니다(`pg_restore --clean --if-exists`).

## 알아둘 점

- healthcheck 기동 속도(TASK-195): Docker는 첫 검사를 `interval` 뒤에 실행한다. keycloak(1m30s)·auth-relay(60s)는 기동 후 각각 90초·60초가 지나야 healthy가 돼 `up -d`가 길어졌다. 이 레포는 `start_period` 동안 `start_interval`(2~5초)로 자주 검사해 준비되는 즉시 healthy가 된다(Docker 25+ 필요). 이관 이전 루트 compose의 keycloak은 그대로라 롤백 `up -d`는 약 2~3분 걸리지만 실패는 아니다.
- `docker compose up`은 `db-backup`을 매번 다시 실행해 덤프를 한 벌 더 만듭니다(보관 개수 초과분은 삭제).
- gateway는 이름으로 keycloak·auth-relay를 찾습니다. 3단계에서 컨테이너가 새로 만들어져도 gateway 재시작 없이 응답했습니다(테스트 서버).
- 루트 compose에서 볼륨 정의를 지워도 실제 볼륨은 삭제되지 않습니다(테스트 서버에서 전환 후에도 볼륨 유지 확인). sandol-auth에서 `down -v`는 하지 않습니다.
- `prometheus.yaml`의 `postgres-exporter-keycloak:9187`은 colocated에서 `sandol_network`로 풀립니다. Keycloak을 다른 서버로 옮기면 target을 바꿉니다.
- 새 서버로 옮길 때: 아래 "새 서버로 이전(덤프 → 복원 → 기동)"과 "별도 서버로 분리할 때 설정"을 따릅니다.

## 별도 서버로 분리할 때 설정 (TASK-186)

바꿀 값 한 표(`<인증IP>` = 인증 서버의 사설 IP, `<메인IP>` = 메인 서버의 사설 IP).

| 서버 | 파일 | 변수 | 값 |
| --- | --- | --- | --- |
| 인증 | sandol-auth `.env` | `COMPOSE_FILE` | 줄 제거(colocated 오버라이드 해제) |
| 인증 | sandol-auth `.env` | `AUTH_BIND_ADDR` | `<인증IP>` (8080·8000·9187 publish 주소) |
| 인증 | sandol-auth `.env` | `KEYCLOAK_EDGE_SUBNET` | `<메인IP>/32` (= `KC_PROXY_TRUSTED_ADDRESSES`, 아래 출발지 확인 필수) |
| 인증 | sandol-auth `.env` | `KC_PUBLIC_URL` | 그대로(issuer 불변) |
| 메인 | 루트 `.env` | `KEYCLOAK_UPSTREAM` | `<인증IP>:8080` |
| 메인 | 루트 `.env` | `AUTH_RELAY_UPSTREAM` | `<인증IP>:8000` |
| 메인 | 루트 `.env` | `KC_INTERNAL_URL` | `http://<인증IP>:8080/auth` (static-info·meal 내부 호출) |
| 메인 | kakao-bot `.env` | `AUTH_RELAY_URL` | `http://<인증IP>:8000/relay` (relay 직접 호출, gateway 경유 아님) |
| 메인 | prometheus 설정 | exporter target | `postgres-exporter-keycloak:9187` → `<인증IP>:9187` |

방화벽(인증 서버): 8080·8000·9187은 **메인 서버 IP만 허용**. 9000(관리·health)과 DB 5432는 publish하지 않으며 열지 않는다.
메인 서버 반영 후 gateway·static-info·meal·kakao-bot·prometheus를 재시작(또는 reload)한다.

출발지 IP 확인(`/32` 전에 필수): 두 서버 사이에 NAT·터널(Cloudflare Tunnel, WireGuard 등)이 있으면 Keycloak이 보는 gateway의 출발지가 `<메인IP>`가 아닐 수 있다. 메인 서버에서 `curl -s -o /dev/null http://<인증IP>:8080/auth/realms/Sandori/.well-known/openid-configuration`을 한 번 호출한 뒤 인증 서버에서 실제 출발지를 본다.
```bash
sudo ss -tn state established '( sport = :8080 )'            # 또는 sudo tcpdump -ni any 'tcp dst port 8080' -c 5
docker compose logs --since 2m keycloak | grep -i -E 'forwarded|proxy' | head   # trusted 아니면 경고
```
여기서 보인 주소(NAT 뒤라면 NAT 장비 주소)를 `/32`로 쓴다. 틀리면 Keycloak이 X-Forwarded-*를 무시해 issuer가 `http://<인증IP>:8080/auth` 쪽으로 어긋난다(.well-known의 `issuer`로 확인).

기동 후 확인(인증 서버, 변수 없이): `docker compose exec auth-relay curl -fsS http://localhost:8000/relay/health`, `ss -ltn | grep -E ':(8080|8000|9187)\b'`로 바인딩 주소가 `<인증IP>`(또는 기본 `127.0.0.1`)인지 본다.
메인 서버 확인: `curl -fsS http://<인증IP>:8000/relay/health`, 공개 `/auth/realms/Sandori/.well-known/openid-configuration`·`/relay/health` 200, 공개 `/relay/issue_login_link` 404, kakao-bot 컨테이너에서 `AUTH_RELAY_URL`의 `/issue_login_link`가 405/422로 도달.

## refresh_token 갱신 확인 (전환·분리 공통)

저장된 refresh_token(특히 `offline_access`)이 재로그인 없이 갱신되는지 **테스트 계정**으로 확인합니다(실제 사용자 토큰은 쓰지 않습니다). `$KC`는 확인할 Keycloak 앞단(공개 `https://<도메인>` 또는 메인 서버 gateway)입니다. 값은 출력하지 않고 파일(권한 600)에만 둡니다.

1. **전환·이전 전**, 기존 Keycloak에서 임시 client·사용자를 만들고 토큰을 받아 둡니다.
   ```bash
   kc(){ docker exec keycloak /opt/keycloak/bin/kcadm.sh "$@"; }
   # 관리자 로그인: kcadm.sh config credentials --server http://localhost:8080/auth --realm master --user <관리자> --password <...>
   kc create clients -r Sandori -s clientId=tmp-split-test-client -s publicClient=true -s directAccessGrantsEnabled=true -s standardFlowEnabled=false -s enabled=true
   kc create users -r Sandori -s username=tmp-split-test-user -s enabled=true -s emailVerified=true -s email=tmp-split-test@example.invalid -s 'attributes.fullname=tmp split'
   kc set-password -r Sandori --username tmp-split-test-user --new-password "<임시 비밀번호>"
   umask 177
   for S in 'openid offline_access:offline' 'openid:online'; do
     curl -s "$KC/auth/realms/Sandori/protocol/openid-connect/token" -d grant_type=password -d client_id=tmp-split-test-client \
       -d username=tmp-split-test-user --data-urlencode "password=<임시 비밀번호>" --data-urlencode "scope=${S%%:*}" \
       | python3 -c 'import sys,json;print(json.load(sys.stdin)["refresh_token"],end="")' > rt-${S##*:}.txt
   done
   ```
   - realm의 user profile에서 `fullname`이 필수라 속성을 줘야 합니다(없으면 `error-user-attribute-required`). 다른 필수 속성이 있으면 `kc get users/profile -r Sandori`로 확인합니다.
   - `offline_access`가 client 기본 scope에 있으면 online 요청도 Offline 토큰이 나옵니다. client의 default-client-scopes에서 `offline_access`를 빼 optional로 옮깁니다(`kc delete clients/<id>/default-client-scopes/<scopeId>`, `kc update clients/<id>/optional-client-scopes/<scopeId>`).
   - 기존 `.env`의 관리자 비밀번호가 `Invalid user credentials`이면(기존 realm에선 부트스트랩 값이 무시됨) 임시 관리자를 만듭니다: `docker exec -e KC_HTTP_MANAGEMENT_PORT=9001 -e P=<pw> keycloak sh -c '/opt/keycloak/bin/kc.sh bootstrap-admin user --username tmp-split-admin --password:env P --no-prompt'`(관리 포트 9000이 이미 쓰여 `9001` 필요). 이 계정도 마지막에 삭제합니다.
2. **전환·이전 후**, 같은 파일로 갱신합니다. HTTP 200과 `iss`가 공개 issuer와 같아야 하고, 갱신된 토큰은 파일에 다시 저장합니다.
   ```bash
   for T in offline online; do
     curl -s -o /tmp/r.json -w "$T http=%{http_code} " "$KC/auth/realms/Sandori/protocol/openid-connect/token" \
       -d grant_type=refresh_token -d client_id=tmp-split-test-client --data-urlencode "refresh_token=$(cat rt-$T.txt)"
     python3 -c 'import json,base64;j=json.load(open("/tmp/r.json"));p=j["access_token"].split(".")[1];p+="="*(-len(p)%4);print("iss",json.loads(base64.urlsafe_b64decode(p))["iss"]) if "access_token" in j else print("error",j.get("error"))'
   done; rm -f /tmp/r.json
   ```
3. **정리**: 임시 사용자·client(·임시 관리자)를 `kc delete users/<id> -r Sandori`, `kc delete clients/<id> -r Sandori`(관리자는 `-r master`)로 지우고, 사용자 수(`select count(*) from user_entity`)가 전과 같은지 봅니다. `rt-*.txt`는 삭제합니다.

테스트 서버 결과: 같은 서버 전환(단계 A)과 덤프·복원 이전(단계 B)에서 offline·online 모두 갱신 200, `iss` 불변이었습니다(issuer·`KC_PUBLIC_URL`이 같고 DB의 realm·키·세션이 그대로 복원되기 때문). 기존 서버로 롤백한 뒤에도 같은 토큰이 200이었습니다.

## 새 서버로 이전 (덤프 → 복원 → 기동)

테스트 서버에서 임시 볼륨으로 모의한 순서입니다. **덤프 전에 Keycloak을 먼저 정지**합니다(쓰기 중 덤프 방지). 기존 서버 `sandol-auth` 디렉터리 기준:

```bash
# 1) 기존 서버: Keycloak 정지 → 덤프 (keycloak-db는 켜 둠)
docker compose stop keycloak auth-relay postgres-exporter-keycloak
docker exec keycloak-db sh -c 'pg_dump -U "$POSTGRES_USER" -d keycloak -Fc -f /tmp/move.dump'
docker cp keycloak-db:/tmp/move.dump ./keycloak-move.dump && docker exec keycloak-db rm /tmp/move.dump
chmod 600 keycloak-move.dump
scp keycloak-move.dump <새 서버>:~/sandol-auth/        # 사설망으로, 전송 후 양쪽 사본 삭제 계획

# 2) 새 서버: 레포 clone·서브모듈·.env(단독: COMPOSE_FILE 줄 없음, AUTH_BIND_ADDR, KEYCLOAK_EDGE_SUBNET)·sandol-auth-relay/.env·clients.json 준비 후
docker compose up -d keycloak-db            # 빈 볼륨이 생기고 DB가 healthy 될 때까지 대기
docker cp keycloak-move.dump keycloak-db:/tmp/restore.dump
docker exec keycloak-db sh -c 'pg_restore -U "$POSTGRES_USER" -d keycloak --clean --if-exists --exit-on-error /tmp/restore.dump; echo exit=$?'
docker exec keycloak-db rm /tmp/restore.dump
docker exec keycloak-db sh -c 'psql -U "$POSTGRES_USER" -d keycloak -tAc "select count(*) from user_entity"'   # 기존 서버 값과 같아야 함

# 3) 새 서버: 전체 기동 (db-backup → keycloak → auth-relay → exporter)
docker compose up -d
# keycloak healthy(1~2분) 대기 후 위 "refresh_token 갱신 확인" 2단계, 메인 서버 값 변경(분리 표)
```

테스트에서 확인한 점(막힌 곳 없음, 아래는 주의):
- `pg_restore --clean --if-exists --exit-on-error`가 빈 DB에서 오류 없이 exit 0이었고, 롤·소유자는 `KC_DB_USERNAME`을 새 `.env`에서 기존과 같게 두면 문제없었습니다(덤프는 소유자를 이 계정으로 기록).
- `keycloak_data` 볼륨은 새 빈 볼륨으로 충분했습니다(`transaction-logs`만 생성). 이전할 필요 없음.
- 사용자 세션(online)·offline 세션도 DB에 있어 그대로 이어졌습니다.
- **exporter는 복원 후 `pg_up 0`**입니다. `sandol_exporter` 롤은 클러스터 단위라 DB 덤프에 없으므로 새 DB에서 `scripts/create-pg-exporter-role.sh`를 실행해야 합니다. 같은 이유로 `PG_EXPORTER_PASSWORD`를 새 `.env`에 넣습니다.
- 확장(extension)은 사용하지 않아 복원 문제가 없었습니다.

**롤백(이전 실패 시)**: ① 메인 서버 변수를 원복합니다(`KEYCLOAK_UPSTREAM`·`AUTH_RELAY_UPSTREAM`·`KC_INTERNAL_URL`·kakao-bot `AUTH_RELAY_URL`·prometheus target을 기본값으로, gateway·static-info·meal·kakao-bot 재시작). ② 기존 서버에서 `docker compose up -d`로 sandol-auth를 다시 기동합니다(원래 볼륨을 쓰므로 기존 토큰 그대로 유효, 이전 도중 기존 서버가 쓰기를 받았다면 그 이후 변경은 새 서버에 없음). ③ 새 서버의 sandol-auth는 `docker compose down`(`-v` 금지). 새 서버가 이미 쓰기를 받았다면(로그인 등) 롤백 시 그만큼 기존 서버 DB와 어긋나므로, 이전은 기존 서버 정지 후 바로 전환하고 문제 시 즉시 롤백합니다.
