# 역방향 SSH 터널 자동 설정 (Reverse SSH Tunnel Auto-Setup)

이 저장소는 공인 IP가 없는 사설망의 서버를 외부에서 접속할 수 있도록, 역방향 SSH 터널을 자동으로 설정하고 관리하는 모든 코드와 문서를 제공합니다.

이 문서 하나만 처음부터 끝까지 따라 하면, 복잡한 네트워크 지식 없이도 재부팅 후에도 자동으로 복구되는 안정적인 원격 접속 환경을 구축할 수 있습니다.

## 목차

1.  [작동 원리 (아키텍처)](#1-작동-원리-아키텍처)
2.  [사전 준비물](#2-사전-준비물)
3.  [설치 절차 (3단계)](#3-설치-절차-3단계)
    - [Step 1: Middle Server 환경 설정 (공인 IP 서버)](#step-1-middle-server-환경-설정-공인-ip-서버)
    - [Step 2: Target Server SSH 설정 (사설망 서버)](#step-2-target-server-ssh-설정-사설망-서버)
    - [Step 3: Target Server 터널 자동화 설정](#step-3-target-server-터널-자동화-설정)
4.  [자동 복구 설정 (재부팅 대응)](#4-자동-복구-설정-재부팅-대응)
5.  [접속 및 확인](#5-접속-및-확인)
6.  [문제 해결 (Troubleshooting)](#6-문제-해결-troubleshooting)
7.  [디렉토리 구조 설명](#7-디렉토리-구조-설명)

---

## 1. 작동 원리 (아키텍처)

이 시스템은 두 대의 서버를 이용하여 작동합니다.

```
[인터넷 사용자] ---> [① Middle Server (공인 IP)] <--- [② SSH 터널] --- [③ Target Server (사설 IP)]
   (ssh, web 등)       (요청 중계)                  (내부에서 외부로 연결)      (실제 작업 서버)
```

-   **① Middle Server (공인 IP 서버):** 공인 IP를 가지고 있어 외부에서 접근 가능한 '관문' 역할을 합니다. (예: 클라우드 VPS, **공인 IP를 가진 라즈베리파이**)
-   **③ Target Server (사설망 서버):** 외부에서 직접 접속할 수 없는, 우리가 최종적으로 접속하고 싶은 서버입니다. 이 서버가 먼저 **② SSH 터널**이라는 통로를 Middle Server로 뚫어놓고 계속 유지합니다.
-   **결과:** 인터넷 사용자는 Middle Server의 특정 포트로 접속하지만, 실제로는 터널을 통해 Target Server와 통신하게 됩니다.

---

## 2. 사전 준비물

-   **Middle Server**: 공인 IP가 할당된 Ubuntu/Debian 계열 리눅스 서버.
-   **Target Server**: 사설망에 위치한 Ubuntu/Debian 계열 리눅스 서버.
-   **Git**: 양쪽 서버에 `git`이 설치되어 있어야 합니다. (`sudo apt-get install git`)

---

## 3. 설치 절차 (3단계)

### Step 1: Middle Server 환경 설정 (공인 IP 서버)

Middle Server에 접속하여, Target Server로부터의 터널 연결을 수신할 환경을 구성합니다.

#### 1-1. 저장소 클론

```bash
git clone https://github.com/your-username/reverse-ssh-tunnel.git  # 본인의 저장소 주소로 변경
cd reverse-ssh-tunnel
```

#### 1-2. 자동화 스크립트 실행

`provision.sh` 스크립트는 터널용 사용자 생성, SSH 설정, 방화벽 규칙 추가를 자동으로 처리합니다.
-   **사용 형식:** `sudo ./middle-server/scripts/provision.sh <사용자이름> <외부포트1> <외부포트2> ...`
-   **실행 예시:** `tunnel`이라는 사용자를 만들고, `22222`번 포트를 외부 터널용으로 열고 싶다면 아래와 같이 실행합니다.

```bash
# Middle Server의 관리용 SSH 포트가 22번이 아니라면, 먼저 해당 포트를 수동으로 열어주세요.
# 예: sudo ufw allow 2222/tcp

sudo ./middle-server/scripts/provision.sh tunnel 22222
```

> **[중요] 1024 이하 포트 사용 시**
> 터널용 외부 포트로 1024 이하(예: 22번)를 사용하려면, 일반 사용자가 해당 포트를 열 수 있도록 추가 권한 설정이 필요합니다.
> ```bash
> # Middle Server에서 실행
> sudo setcap 'cap_net_bind_service=+ep' $(which sshd)
> ```

---

### Step 2: Target Server SSH 설정 (사설망 서버)

Target Server가 Middle Server에 비밀번호 없이 안전하게 접속할 수 있도록 설정합니다.
> **[중요]** 이 단계의 모든 작업은 **터널을 실행할 사용자 계정**(예: `jy`)으로 로그인하여 진행해야 합니다.

#### 2-1. SSH 키 생성 및 등록

1.  **키 생성** (이미 있다면 건너뛰기):
    ```bash
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_tunnel -C "reverse-tunnel-key"
    ```
2.  **공개키 복사**: `cat ~/.ssh/id_ed25519_tunnel.pub` 명령으로 출력된 키 전체를 복사합니다.
3.  **Middle Server에 공개키 등록**:
    -   Middle Server에 `tunnel` 사용자로 접속합니다. (`ssh tunnel@<middle_ip> -p <관리용_ssh_포트>`)
    -   아래 명령 실행:
        ```bash
        mkdir -p ~/.ssh; chmod 700 ~/.ssh
        echo "여기에_복사한_공개키_붙여넣기" >> ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        exit
        ```

#### 2-2. SSH 클라이언트 설정 (`~/.ssh/config`)

**Target Server에서** `nano ~/.ssh/config` 명령으로 파일을 열고, 아래 내용을 **정확하게** 입력합니다. 이는 접속 정보를 저장하는 '주소록' 역할을 합니다.

```ssh-config
# 'pitunnel'은 이 연결을 부를 별칭입니다. 자유롭게 변경 가능합니다.
Host pitunnel
  HostName <YOUR_MIDDLE_SERVER_IP>  # Middle Server의 실제 공인 IP 주소
  User tunnel                       # Middle Server에 생성한 터널용 사용자
  Port <관리용_SSH_포트>            # Middle Server의 SSH 접속 포트 (예: 2222)
  IdentityFile ~/.ssh/id_ed25519_tunnel # 터널링에 사용할 개인 키 파일
```
파일 저장 후, `chmod 600 ~/.ssh/config` 명령으로 권한을 설정합니다.

#### 2-3. 연결 최종 테스트

**Target Server에서** `ssh pitunnel` 명령으로 Middle Server에 비밀번호 없이 접속되는지 확인합니다. 성공하면 `exit`로 돌아옵니다.

---

### Step 3: Target Server 터널 자동화 설정

`setup.sh` 스크립트로 터널을 자동으로 실행하고 유지하도록 설정합니다.

#### 3-1. 저장소 클론 및 설정 파일 준비

```bash
# Target Server에서 실행
git clone https://github.com/your-username/reverse-ssh-tunnel.git
cd reverse-ssh-tunnel

# 설정 파일 복사 및 수정
cp target-server/config/tunnel.conf.example target-server/config/tunnel.conf
nano target-server/config/tunnel.conf
```
`tunnel.conf` 파일의 내용을 아래와 같이 수정합니다.

```ini
# MIDDLE_SERVER_IP에 ~/.ssh/config에서 정한 Host 별칭을 입력합니다.
MIDDLE_SERVER_IP="pitunnel"
# MIDDLE_SERVER_USER에 Middle Server의 터널용 사용자를 입력합니다.
MIDDLE_SERVER_USER="tunnel"
# "외부포트:내부IP:내부포트" 형식으로 터널을 설정합니다.
# 외부에서 pitunnel의 22222번 포트로 접속하면 -> 이 Target Server의 22번 포트로 연결됩니다.
TUNNELS="22222:localhost:22"
```

#### 3-2. 자동화 스크립트 실행

`setup.sh` 스크립트를 **터널을 실행할 사용자 계정(Step 2를 진행한 사용자)에서 `sudo`를 붙여 실행**합니다.

```bash
# reverse-ssh-tunnel 디렉토리에서 실행
sudo ./target-server/scripts/setup.sh
```
스크립트가 모든 설정을 자동으로 완료합니다.

---

## 4. 자동 복구 설정 (재부팅 대응)

이 시스템이 재부팅 후에도 자동으로 작동하게 하려면, 각 서버의 서비스들이 부팅 시 자동으로 시작되어야 합니다.

-   **Target Server:**
    -   이미 **Step 3**에서 `setup.sh`를 통해 `systemd` 서비스가 등록되었으므로, 재부팅 시 자동으로 터널 생성을 시도합니다. **추가 작업이 필요 없습니다.**

-   **Middle Server (라즈베리파이 등):**
    -   SSH 서버와 방화벽이 부팅 시 자동으로 활성화되는지 확인해야 합니다.
    ```bash
    # Middle Server에서 실행

    # 1. SSH 서버 자동 시작 활성화 (보통 이미 'enabled' 상태)
    sudo systemctl enable sshd

    # 2. 방화벽 자동 시작 활성화 (이미 'active' 상태면 OK)
    sudo ufw enable
    ```
    위 두 가지가 확인되면 Middle Server도 재부팅 후 자동으로 제 역할을 수행할 준비가 된 것입니다.

---

## 5. 접속 및 확인

모든 설정이 완료되면, 인터넷이 되는 어떤 PC에서든 아래와 같이 접속할 수 있습니다.

-   **Target Server로 SSH 접속:**
    ```bash
    # Middle Server의 터널 포트로 접속
    # <사용자>는 최종 목적지인 Target Server에 로그인할 계정 이름입니다.
    ssh -p 22222 <사용자>@pitunnel
    ```

-   **서비스 상태 확인:**
    -   **Target Server:** `systemctl status reverse-tunnel.service` -> `active (running)` 상태인지 확인
    -   **Middle Server:** `ss -tlnp | grep 22222` -> `sshd`가 터널 포트를 열고 있는지 확인

---

## 6. 문제 해결 (Troubleshooting)

-   **`setup.sh` 실행 시 'SSH 연결 실패' 메시지가 나올 경우:**
    -   `README.md`의 **Step 2**를 처음부터 다시 꼼꼼히 확인하세요.
    -   **Target Server**에서 `ssh -v pitunnel` 명령을 실행하여 상세한 디버그 로그를 확인하세요.

-   **서비스가 `activating (auto-restart)` 상태에서 벗어나지 못할 경우:**
    -   **Target Server**에서 `journalctl -u reverse-tunnel.service -f` 명령으로 실시간 로그를 확인하여 정확한 오류 메시지를 찾으세요.
    -   `Error: remote port forwarding failed for listen port ...` 메시지가 보인다면, Middle Server의 포트 권한 문제 또는 방화벽 문제입니다.

---

## 7. 디렉토리 구조 설명

-   **middle-server/**: 공인 IP를 가진 중계 서버의 자동 설정을 위한 스크립트와 문서.
-   **target-server/**: 사설망에 위치한 목적 서버의 터널 자동 생성을 위한 스크립트와 설정 파일.
  -   `config/`: 터널링 상세 설정 파일.
  -   `systemd/`: 터널 자동 실행 및 유지를 위한 서비스 파일 템플릿.
  -   `scripts/`: 터널 실행 및 자동 설치 스크립트.