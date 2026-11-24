# sandol-auth

산돌이 인증 스택(Keycloak, Keycloak DB, auth-relay)을 독립 compose 프로젝트(`name: sandol-auth`)로 운영하는 레포입니다.
루트 레포 [tuk_sandol_team](https://github.com/teamSANDOL/tuk_sandol_team)에서 분리했으며(TASK-185), Keycloak을 별도 서버로 옮길 때 새 서버에서 이 레포만 clone해 띄우는 것이 목적입니다.

## 구성

| 서비스 | 컨테이너 | 설명 |
| --- | --- | --- |
| keycloak-db | `keycloak-db` | Keycloak PostgreSQL (볼륨 `keycloak_db_data`) |
| keycloak | `keycloak` | Keycloak 26.8.1, 테마·Apple IdP jar는 `sandol_user_service` 서브모듈 |
| postgres-exporter-keycloak | `postgres-exporter-keycloak` | Prometheus용 DB exporter |
| auth-relay | `auth-relay` | 챗봇 로그인 중계(`sandol-auth-relay` 서브모듈) |
| db-backup | `sandol-auth-db-backup` | Keycloak 기동 전 `pg_dump` one-shot. 실패하면 keycloak이 뜨지 않음(fail-closed) |

| 파일 | 용도 |
| --- | --- |
| `docker-compose.yml` | 단독 기동용 기본 구성 |
| `docker-compose.colocated.yml` | 같은 서버에서 루트 프로젝트와 함께 띄울 때만 겹쳐 쓰는 오버라이드(전환 기간) |
| `docker-compose.auth-bak.yml` / `docker-compose.auth-restore.yml` | realm export / import 일회성 작업 |
| `scripts/db-backup.sh` | 백업 스크립트 |
| `scripts/create-pg-exporter-role.sh` | exporter 계정 생성 |
| `docs/migration.md` | 루트에서 이관하는 절차와 롤백 |

## 서브모듈 초기화

```bash
git clone https://github.com/teamSANDOL/sandol-auth && cd sandol-auth
git submodule update --init
cp .env.example .env                       # 값 채우기
cp <기존>/sandol-auth-relay/.env sandol-auth-relay/.env   # auth-relay 설정
```

서브모듈 커밋은 루트 레포의 gitlink와 같은 커밋에 고정되어 있습니다(`sandol_user_service`, `sandol-auth-relay`).
`.gitmodules`가 SSH URL이라 키가 없으면 `git -c url.https://github.com/.insteadOf=git@github.com: submodule update --init`을 씁니다.

## 필요한 파일

- `.env`: `.env.example` 참고. `COMPOSE_PROJECT_NAME`은 넣지 않습니다(`name: sandol-auth`를 덮어씁니다).
- `sandol-auth-relay/.env`: auth-relay 설정(서브모듈 README 참고).
- `${SANDOL_DATA_DIR}/auth-relay/clients.json`: auth-relay 클라이언트 목록(읽기 전용 마운트).

## 단독 기동(새 서버)

```bash
docker compose up -d
```

- 볼륨이 없으면 빈 볼륨이 만들어져 **새 Keycloak**으로 뜹니다. 기존 데이터를 옮길 때는 먼저 `docs/migration.md`의 복원 절차(`docker-compose.auth-restore.yml`)를 따릅니다.
- 이 compose는 포트를 호스트에 열지 않습니다. 앞단 프록시(gateway)가 `keycloak:8080/auth`, `auth-relay:8000/relay`에 닿도록 같은 네트워크에 붙이는 것은 별도 작업입니다(범위 밖).
- `KC_PUBLIC_URL`(예: `https://sandori.kr/auth`)이 issuer를 정합니다. 바꾸면 기존 토큰의 issuer가 달라집니다.

## 같은 서버에서 루트와 함께 기동(colocated)

루트 프로젝트(`tuk_sandol_team`)가 한 번이라도 떠서 `sandol_network`, `sandol_keycloak_edge` 네트워크와 Keycloak 볼륨이 있어야 합니다.

```bash
docker compose -f docker-compose.yml -f docker-compose.colocated.yml up -d
```

- keycloak·auth-relay·exporter가 루트의 `sandol_network`에 붙어 다른 서비스가 `http://keycloak:8080/auth`, `http://auth-relay:8000/relay`로 계속 접근합니다.
- keycloak은 `sandol_keycloak_edge`에 `keycloak-edge` 별칭으로 붙습니다(gateway가 이 이름으로 프록시, `KC_PROXY_TRUSTED_ADDRESSES`는 이 서브넷).
- 네트워크·볼륨 이름은 루트 `COMPOSE_PROJECT_NAME` 접두사가 붙은 실제 이름입니다. `docker network ls`, `docker volume ls`로 확인하고 `.env`의 `SANDOL_NETWORK_NAME`, `KEYCLOAK_DB_VOLUME`, `KEYCLOAK_DATA_VOLUME`을 맞춥니다.
- 오버라이드는 볼륨을 `external: true`로 바꿉니다. 이름이 틀리면 빈 볼륨을 만들지 않고 `external volume ... not found`로 멈춥니다.

## 볼륨 이름 고정 방식

`keycloak_db_data`, `keycloak_data`는 `name: ${KEYCLOAK_DB_VOLUME:-...}`로 이름을 고정해 기존 루트 프로젝트 볼륨(`<루트 프로젝트명>_keycloak_*`)에 그대로 붙습니다.
기본 compose는 non-external이라 빈 서버에서 자동 생성되고, colocated 오버라이드는 external이라 기존 볼륨이 없으면 에러로 멈춥니다(테스트 서버에서 두 동작 모두 확인).

## 백업

`db-backup`은 `up`할 때마다 `${SANDOL_AUTH_BACKUP_DIR:-${SANDOL_DATA_DIR}/backups-auth}/<UTC 타임스탬프>/keycloak.dump`를 만듭니다. 보관 개수는 `BACKUP_KEEP`(기본 10). 수동 실행: `docker compose run --rm db-backup`.
realm 단위 export/import는 `docker-compose.auth-bak.yml`, `docker-compose.auth-restore.yml`을 사용합니다.

## 주의

- `docker compose down -v`는 Keycloak 데이터를 지울 수 있으므로 쓰지 않습니다.
- 테스트 도메인, 서버 IP, 비밀값은 커밋하지 않습니다.
