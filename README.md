# 역방향 SSH 터널 자동 설정

공인 IP가 없는 사설망 서버(Target Server)에 외부에서 접속할 수 있도록, 공인 IP가 있는 서버(Middle Server)를 경유하는 역방향 SSH 터널을 설정하는 프로젝트입니다.

Target Server가 Middle Server로 먼저 SSH 연결을 만들고 유지합니다. 외부 사용자는 Middle Server의 지정 포트로 접속하지만, 실제 트래픽은 터널을 통해 Target Server의 SSH, RDP, 웹 서비스 등으로 전달됩니다.

```text
[외부 사용자] -> [Middle Server:공인 IP] <- reverse ssh tunnel <- [Target Server:사설망]
```

## 구조

```text
middle-server/
  config/middle.conf.example      Middle Server 설정 예시
  scripts/provision.sh            터널 사용자, sshd, ufw 설정
  scripts/uninstall.sh            Middle Server 설정 제거

target-server/
  config/tunnel.conf.example      Target Server 터널 설정 예시
  scripts/setup.sh                autossh, systemd, 키 등록 설정
  scripts/start-tunnel.sh         systemd가 실행하는 터널 시작 스크립트
  scripts/uninstall.sh            Target Server 설정 제거
  systemd/reverse-tunnel.service  systemd 서비스 템플릿
```

`middle-server/config/middle.conf`와 `target-server/config/tunnel.conf`는 로컬 환경 설정 파일입니다. 저장소에는 예시 파일만 추적되며, 실제 설정 파일은 각 서버에서 `.example`을 복사해서 만듭니다.

## 1. Middle Server 설정

Middle Server는 공인 IP가 있고 외부에서 SSH 접속 가능한 서버입니다.

```bash
git clone https://github.com/nachalsa/reverse-tunnel.git
cd reverse-tunnel
cp middle-server/config/middle.conf.example middle-server/config/middle.conf
nano middle-server/config/middle.conf
sudo ./middle-server/scripts/provision.sh
```

주요 설정:

```bash
TUNNEL_USER="tunnel"
TUNNEL_PORTS_TO_OPEN="22222 8080"
ENABLE_UFW="false"
```

- `TUNNEL_USER`: Middle Server에 생성할 터널 전용 사용자입니다.
- `TUNNEL_PORTS_TO_OPEN`: 외부에 노출할 Middle Server 포트 목록입니다.
- `ENABLE_UFW`: `true`이면 UFW가 꺼져 있을 때 스크립트가 활성화합니다. 원격 서버에서는 기존 서비스 차단 위험이 있으므로 기본값 `false`를 권장합니다.

관리용 SSH 포트는 스크립트가 `sshd` 설정에서 자동 감지해 UFW 허용 규칙에 함께 추가합니다.

`provision.sh`는 `/etc/ssh/sshd_config` 끝에 터널 사용자 전용 `Match User` 블록을 추가합니다. 전역 `GatewayPorts yes`를 넣지 않고, 터널 사용자에게만 원격 포트 공개 바인딩을 허용합니다.

## 2. Target Server 설정

Target Server는 사설망 내부에 있는 실제 접속 대상 서버입니다. 터널을 실행할 일반 사용자 계정으로 로그인한 뒤 진행합니다.

먼저 Target Server에서 Middle Server 관리자 계정으로 SSH 접속 가능한 별칭을 준비합니다.

```ssh-config
Host hosting-server
  HostName <middle-server-public-ip>
  User <admin-user>
```

비밀번호 없이 접속되도록 공개키를 등록합니다.

```bash
ssh-copy-id hosting-server
ssh hosting-server true
```

그 다음 Target Server에서 이 프로젝트를 설정합니다.

```bash
git clone https://github.com/nachalsa/reverse-tunnel.git
cd reverse-tunnel
cp target-server/config/tunnel.conf.example target-server/config/tunnel.conf
nano target-server/config/tunnel.conf
sudo ./target-server/scripts/setup.sh
```

`setup.sh` 실행 중 "관리자 접속용 별칭"을 물으면 위에서 만든 `hosting-server` 같은 별칭을 입력합니다. 스크립트가 해당 별칭에서 `HostName`과 `Port`를 읽어 터널 전용 SSH 설정을 자동으로 추가합니다.

주요 설정:

```bash
MIDDLE_SERVER_HOST_ALIAS="pitunnel"
MIDDLE_SERVER_TUNNEL_USER="tunnel"
TUNNELS="22222:localhost:22"
```

- `MIDDLE_SERVER_HOST_ALIAS`: Target Server의 `~/.ssh/config`에 생성할 터널 전용 별칭입니다.
- `MIDDLE_SERVER_TUNNEL_USER`: Middle Server의 터널 전용 사용자입니다.
- `TUNNELS`: `"외부포트:내부호스트:내부포트"` 형식입니다.

예시:

```bash
# Target Server의 SSH를 Middle Server의 22222번으로 노출
TUNNELS="22222:localhost:22"

# Target Server의 RDP를 Middle Server의 8009번으로 노출
TUNNELS="8009:localhost:3389"

# 여러 터널 동시 사용
TUNNELS="22222:localhost:22 8009:localhost:3389"
```

## 3. 접속

외부 PC에서는 Middle Server의 공인 IP 또는 DNS 이름과 터널 포트로 접속합니다.

```bash
ssh -p 22222 <target-server-user>@<middle-server-public-ip>
```

RDP를 `8009:localhost:3389`로 열었다면 RDP 클라이언트에서 다음 주소로 접속합니다.

```text
<middle-server-public-ip>:8009
```

## 4. 상태 확인

Target Server:

```bash
systemctl status reverse-tunnel.service
journalctl -u reverse-tunnel.service -f
```

Middle Server:

```bash
ss -tlnp | grep 22222
sudo ufw status verbose
sudo sshd -T -C user=tunnel | grep -E '^(gatewayports|allowtcpforwarding) '
```

## 5. 제거

Target Server:

```bash
sudo ./target-server/scripts/uninstall.sh
```

기본적으로 `autossh` 패키지는 삭제하지 않습니다. 패키지까지 제거하려면 다음처럼 실행합니다.

```bash
REMOVE_AUTOSSH=true sudo -E ./target-server/scripts/uninstall.sh
```

Middle Server:

```bash
sudo ./middle-server/scripts/uninstall.sh
```

## 6. 주의사항

- `ENABLE_UFW=true`는 원격 서버의 다른 포트를 막을 수 있습니다. 서버에서 이미 운영 중인 서비스가 있다면 UFW 규칙을 먼저 확인하세요.
- 1024 이하 포트를 터널 외부 포트로 쓰는 구성은 피하는 것을 권장합니다. 일반적으로 `22222`, `8001`, `8009`처럼 1024보다 큰 포트를 사용하세요.
- `TUNNELS`의 외부 포트는 Middle Server에서 비어 있어야 합니다. 이미 사용 중인 포트면 `ExitOnForwardFailure=yes` 때문에 서비스 시작이 실패합니다.
