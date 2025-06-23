# 역방향 SSH 터널 자동 설정 (Reverse SSH Tunnel Auto-Setup)

이 저장소는 공인 IP가 없는 사설망의 서버(예: 라즈베리파이)를 외부에서 접속할 수 있도록, 역방향 SSH 터널을 자동으로 설정하고 관리하는 모든 코드와 문서를 제공합니다.

이 문서 하나만 처음부터 끝까지 따라 하면, 복잡한 네트워크 지식 없이도 안정적인 원격 접속 환경을 구축할 수 있습니다.

## 목차

1.  [작동 원리 (아키텍처)](#1-작동-원리-아키텍처)
2.  [사전 준비물](#2-사전-준비물)
3.  [설치 절차 (3단계)](#3-설치-절차-3단계)
    - [Step 1: Middle Server 환경 설정 (외부 서버)](#step-1-middle-server-환경-설정-외부-서버)
    - [Step 2: Target Server SSH 설정 (내부 서버)](#step-2-target-server-ssh-설정-내부-서버)
    - [Step 3: Target Server 터널 자동화 설정](#step-3-target-server-터널-자동화-설정)
4.  [접속 및 확인](#4-접속-및-확인)
5.  [문제 해결 (Troubleshooting)](#5-문제-해결-troubleshooting)
6.  [디렉토리 구조 설명](#6-디렉토리-구조-설명)

---

## 1. 작동 원리 (아키텍처)

이 시스템은 두 대의 서버를 이용하여 작동합니다.

```
[인터넷 사용자] ---> [① Middle Server (공인 IP)] <--- [② SSH 터널] --- [③ Target Server (사설 IP)]
   (ssh, web 등)       (요청 중계)                  (내부에서 외부로 연결)      (실제 작업 서버)
```

-   **③ Target Server (내부 서버, 예: 라즈베리파이):** 외부에서 접속할 수 없는 사설망에 있습니다. 이 서버가 먼저 **② SSH 터널**이라는 통로를 **① Middle Server**로 뚫어놓고 계속 유지합니다.
-   **① Middle Server (외부 서버, 예: 클라우드 VPS):** 공인 IP를 가지고 있어 외부에서 접근 가능합니다. Target Server가 만들어 놓은 터널을 통해 들어오는 요청을 중계해주는 '교차로' 역할을 합니다.
-   **결과:** 인터넷 사용자는 Middle Server의 특정 포트로 접속하지만, 실제로는 터널을 통해 Target Server와 통신하게 됩니다.

---

## 2. 사전 준비물

-   **Middle Server**: 공인 IP가 할당된 Ubuntu/Debian 계열 리눅스 서버 (예: AWS, GCP, Vultr 등 클라우드 VPS).
-   **Target Server**: 사설망에 위치한 Ubuntu/Debian 계열 리눅스 서버 (예: 라즈베리파이).
-   **Git**: Target Server에 `git`이 설치되어 있어야 합니다. (`sudo apt-get install git`)

---

## 3. 설치 절차 (3단계)

### Step 1: Middle Server 환경 설정 (외부 서버)

Middle Server에 접속하여, Target Server로부터의 터널 연결을 수신할 환경을 구성합니다.

#### 1-1. 터널 전용 사용자 생성

보안을 위해 root가 아닌 전용 사용자(`tunnel_user`)를 생성합니다.

```bash
sudo adduser tunnel_user
```
(비밀번호 등 정보를 입력하여 사용자를 생성합니다.)

#### 1-2. SSH 서버 설정

터널 포트가 외부 IP(`0.0.0.0`)에 바인딩되도록 `GatewayPorts` 옵션을 활성화합니다.

1.  `sshd_config` 파일 열기:
    ```bash
    sudo nano /etc/ssh/sshd_config
    ```
2.  파일 맨 아래에 다음 라인을 추가:
    ```sshd-config
    GatewayPorts yes
    ```
3.  SSH 서비스 재시작:
    ```bash
    sudo systemctl restart sshd
    ```

#### 1-3. 방화벽 설정

외부에서 접속할 터널 포트를 방화벽에서 허용합니다. 어떤 포트를 열지는 **Step 3**에서 결정하게 됩니다. 여기서는 예시로 `8022`(SSH용), `8080`(웹용) 포트를 열겠습니다.

```bash
# ufw (Uncomplicated Firewall) 사용 시
sudo ufw allow ssh          # 22번 포트 (서버 관리용)
sudo ufw allow 8022/tcp
sudo ufw allow 8080/tcp
sudo ufw enable
sudo ufw status
```

---

### Step 2: Target Server SSH 설정 (내부 서버)

Target Server가 Middle Server에 **비밀번호 없이 안전하게 접속**할 수 있도록 SSH 키 기반 인증을 설정합니다.

> **[중요]** 이 단계의 모든 작업은 **터널을 실행할 사용자 계정**(예: 라즈베리파이의 기본 사용자인 `pi` 또는 `ubuntu`)으로 로그인하여 진행해야 합니다. 이 단계의 목표는 `ssh <middle_server_ip>`를 입력했을 때, 비밀번호 없이 즉시 접속되게 만드는 것입니다.

#### 2-1. SSH 키 생성

터널링 전용 SSH 키를 생성합니다. 비밀번호(passphrase)는 입력하지 않고 Enter를 눌러 넘어갑니다.

```bash
# 터널을 실행할 사용자로 로그인한 상태에서 실행
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa_tunnel -C "reverse-tunnel-key"
```

#### 2-2. Middle Server에 공개키 등록

1.  **Target Server에서** 방금 생성한 공개키(`id_rsa_tunnel.pub`)의 내용을 복사합니다.
    ```bash
    cat ~/.ssh/id_rsa_tunnel.pub
    ```
2.  **Middle Server에** `tunnel_user`로 접속하여, 복사한 키를 `authorized_keys` 파일에 등록합니다.
    ```bash
    # tunnel_user로 로그인한 상태에서 실행
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    echo "위에서_복사한_공개키_내용_전체를_여기에_붙여넣기" >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    ```

#### 2-3. SSH 클라이언트 설정 (`~/.ssh/config`)

1.  **Target Server에서** `~/.ssh/config` 파일을 엽니다. (파일이 없으면 새로 생성됩니다)
    ```bash
    nano ~/.ssh/config
    ```
2.  아래 내용을 파일에 추가합니다. `<YOUR_MIDDLE_SERVER_IP>`는 실제 Middle Server의 IP로 변경하세요.
    ```ssh-config
    Host <YOUR_MIDDLE_SERVER_IP>
      HostName <YOUR_MIDDLE_SERVER_IP>
      User tunnel_user
      IdentityFile ~/.ssh/id_rsa_tunnel
    ```
3.  파일 권한을 설정합니다.
    ```bash
    chmod 600 ~/.ssh/config
    ```

#### 2-4. 연결 최종 테스트

**Target Server에서** 아래 명령어로 Middle Server에 비밀번호 없이 접속되는지 확인합니다.

```bash
ssh <YOUR_MIDDLE_SERVER_IP>
```
"Welcome to..." 메시지와 함께 접속에 성공하면, 모든 SSH 설정이 올바르게 완료된 것입니다. `exit`를 입력하여 원래 서버로 돌아옵니다.

---

### Step 3: Target Server 터널 자동화 설정

이 저장소의 스크립트를 사용하여 터널을 자동으로 실행하고, 끊어지더라도 계속 유지하도록 설정합니다.

#### 3-1. 저장소 클론 및 설정 파일 준비

```bash
# Target Server에서 실행
git clone https://github.com/your-username/reverse-ssh-tunnel.git  # 본인의 저장소 주소로 변경
cd reverse-ssh-tunnel

# 설정 파일 복사
cp target-server/config/tunnel.conf.example target-server/config/tunnel.conf

# 설정 파일 수정 (가장 중요한 단계)
nano target-server/config/tunnel.conf
```

`tunnel.conf` 파일을 열고, `MIDDLE_SERVER_IP`와 `TUNNELS` 목록을 자신의 환경에 맞게 수정합니다. **`TUNNELS` 설정이 가장 중요합니다.**

##### `TUNNELS` 항목 설정 방법

`TUNNELS`는 `"외부포트:내부IP:내부포트"` 형식의 조합을 공백으로 구분하여 나열하는 문자열입니다. 아래 시나리오를 참고하여 자신의 목적에 맞게 수정하세요.

-   **시나리오 1: 사설망의 Target Server에 SSH로 접속하고 싶을 때**
    -   **목표:** 내 PC에서 `ssh -p 8022 user@<middle_ip>`를 입력하여 Target Server에 접속.
    -   **설정:** `TUNNELS="8022:localhost:22"`
    -   **설명:** 외부에서 Middle Server의 `8022`번 포트로 들어온 요청을 Target Server 자신(`localhost`)의 `22`번 포트(SSH)로 전달합니다.

-   **시나리오 2: 사설망의 Target Server에서 실행 중인 웹 서비스를 외부에서 보고 싶을 때**
    -   **목표:** 웹 브라우저에서 `http://<middle_ip>:8080`을 입력하여 웹 페이지 확인.
    -   **설정:** `TUNNELS="8080:localhost:80"`
    -   **설명:** 외부에서 Middle Server의 `8080`번 포트로 들어온 요청을 Target Server 자신(`localhost`)의 `80`번 포트(HTTP)로 전달합니다.

-   **시나리오 3: 사설망의 다른 PC (예: 192.168.1.50)에 있는 윈도우 원격 데스크톱에 접속하고 싶을 때**
    -   **목표:** 내 PC의 원격 데스크톱 클라이언트에서 `<middle_ip>:13389`로 접속.
    -   **설정:** `TUNNELS="13389:192.168.1.50:3389"`
    -   **설명:** 외부에서 Middle Server의 `13389`번 포트로 들어온 요청을 사설망의 `192.168.1.50` PC의 `3389`번 포트(RDP)로 전달합니다.

-   **시나리오 4: 위 세 가지를 모두 사용하고 싶을 때**
    -   **설정:** `TUNNELS="8022:localhost:22 8080:localhost:80 13389:192.168.1.50:3389"`
    -   **설명:** 각 설정을 공백으로 구분하여 한 줄에 모두 적어줍니다.

**주의:** `외부포트`는 **Step 1-3**에서 Middle Server의 방화벽에서 허용한 포트와 일치해야 합니다.

#### 3-2. 자동화 스크립트 실행

`setup.sh` 스크립트를 **터널을 실행할 사용자 계정(Step 2를 진행한 사용자)에서 `sudo`를 붙여 실행**합니다. 스크립트는 `sudo`를 실행한 사용자를 자동으로 인식하여 모든 설정을 완료합니다.

```bash
# reverse-ssh-tunnel 디렉토리에서 실행
sudo ./target-server/scripts/setup.sh
```
스크립트가 `autossh` 설치, SSH 연결 테스트, 파일 복사, 서비스 등록 및 시작을 모두 자동으로 처리합니다.

---

## 4. 접속 및 확인

모든 설정이 완료되면, 인터넷이 되는 어떤 PC에서든 아래와 같이 접속할 수 있습니다.

-   **Target Server로 SSH 접속:**
    ```bash
    # Middle Server의 8022 포트로 접속 (예시)
    ssh <target_server_user>@<middle_server_ip> -p 8022
    ```

-   **Target Server의 웹 서비스 접속:**
    -   웹 브라우저 주소창에 `http://<middle_server_ip>:8080` 입력 (예시)

-   **서비스 상태 확인:**
    -   **Target Server에서:** `systemctl status reverse-tunnel.service` (active (running) 상태인지 확인)
    -   **Middle Server에서:** `ss -tlnp | grep 8022` (sshd가 터널 포트를 열고 있는지 확인)

---

## 5. 문제 해결 (Troubleshooting)

-   **`setup.sh` 실행 시 'SSH 연결 실패' 메시지가 나올 경우:**
    -   `README.md`의 **Step 2**를 처음부터 다시 꼼꼼히 확인하세요.
    -   **Target Server**에서 `ssh -v <middle_server_ip>` 명령을 실행하여 상세한 디버그 로그를 확인하세요. `Permission denied (publickey)` 에러가 보인다면 키 등록 문제일 가능성이 높습니다.

-   **서비스가 active (running) 상태가 아닌 경우:**
    -   **Target Server**에서 `journalctl -u reverse-tunnel.service -f` 명령을 실행하여 실시간 로그를 확인하세요.
    -   로그에 `port_listen failed for...` 메시지가 있다면, **Middle Server**의 해당 포트가 이미 다른 프로세스에 의해 사용 중이거나, `GatewayPorts` 설정이 제대로 되지 않았을 수 있습니다.
    -   **Middle Server**에서 `ss -tlnp | grep <포트번호>` 명령으로 포트 사용 상태를 확인하세요.

---

## 6. 디렉토리 구조 설명

-   **middle-server/**: 공인 IP를 가진 중계 서버 관련 폴더. 현재는 수동 설정을 따르지만, 향후 Ansible 등 자동화 도구를 위한 스크립트를 추가할 수 있는 구조입니다.
-   **target-server/**: 사설망에 위치한 목적 서버 관련 폴더.
  -   `config/`: 터널링 상세 설정 파일.
  -   `systemd/`: 터널 자동 실행 및 유지를 위한 서비스 파일 템플릿.
  -   `scripts/`: 터널 실행 및 자동 설치 스크립트.