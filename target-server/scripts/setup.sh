#!/bin/bash
set -euo pipefail

# --- 사전 검증 및 변수 정의 ---
if [ "$(id -u)" -ne 0 ]; then
    echo "오류: 이 스크립트는 root 권한으로 실행해야 합니다. (sudo ./setup.sh)"
    exit 1
fi
if [ -z "${SUDO_USER:-}" ]; then
    echo "오류: root로 직접 로그인하지 마십시오. 일반 사용자 계정에서 'sudo ./setup.sh'를 실행하세요."
    exit 1
fi
SERVICE_USER="$SUDO_USER"

if ! id "$SERVICE_USER" &>/dev/null; then
    echo "오류: '${SERVICE_USER}' 사용자를 찾을 수 없습니다."
    exit 1
fi

PROJECT_ROOT=$(dirname "$(readlink -f "$0")")/..
INSTALL_DIR="/opt/reverse-tunnel"
CONFIG_FILE="${PROJECT_ROOT}/config/tunnel.conf"
USER_HOME=$(getent passwd "$SERVICE_USER" | cut -d: -f6)
USER_SSH_DIR="${USER_HOME}/.ssh"
USER_SSH_CONFIG="${USER_SSH_DIR}/config"
USER_TUNNEL_KEY="${USER_SSH_DIR}/id_ed25519_tunnel"

run_as_service_user() {
    sudo -u "$SERVICE_USER" "$@"
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

validate_required_config() {
    MIDDLE_SERVER_TUNNEL_USER="${MIDDLE_SERVER_TUNNEL_USER:-tunnel}"

    if ! [[ "${MIDDLE_SERVER_HOST_ALIAS:-}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "오류: MIDDLE_SERVER_HOST_ALIAS 값이 유효하지 않습니다."
        exit 1
    fi

    if ! [[ "$MIDDLE_SERVER_TUNNEL_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
        echo "오류: MIDDLE_SERVER_TUNNEL_USER 값('${MIDDLE_SERVER_TUNNEL_USER}')이 유효한 리눅스 사용자 이름 형식이 아닙니다."
        exit 1
    fi

    if [ -z "${TUNNELS:-}" ]; then
        echo "오류: TUNNELS 값이 설정되어 있지 않습니다."
        exit 1
    fi

    local tunnel remote_port target_host target_port
    for tunnel in $TUNNELS; do
        IFS=: read -r remote_port target_host target_port <<EOF
$tunnel
EOF
        if [ -z "${remote_port:-}" ] || [ -z "${target_host:-}" ] || [ -z "${target_port:-}" ]; then
            echo "오류: 터널 형식이 올바르지 않습니다: ${tunnel}"
            exit 1
        fi
        if ! validate_port "$remote_port" || ! validate_port "$target_port"; then
            echo "오류: 터널 포트 값이 올바르지 않습니다: ${tunnel}"
            exit 1
        fi
        if ! [[ "$target_host" =~ ^[A-Za-z0-9._-]+$ ]]; then
            echo "오류: 터널 대상 호스트 값이 올바르지 않습니다: ${tunnel}"
            exit 1
        fi
    done
}

ssh_host_exists() {
    local alias="$1"
    run_as_service_user grep -Eiq "^[[:space:]]*Host[[:space:]]+${alias}([[:space:]]|$)" "${USER_SSH_CONFIG}" 2>/dev/null
}

ssh_config_value() {
    local config_dump="$1"
    local key="$2"
    printf '%s\n' "$config_dump" | awk -v key="$key" '$1 == key { print $2; exit }'
}

validate_existing_tunnel_host() {
    local current_dump current_hostname current_user current_port current_identity

    if ! current_dump=$(run_as_service_user ssh -F "${USER_SSH_CONFIG}" -G "${MIDDLE_SERVER_HOST_ALIAS}"); then
        echo "오류: 기존 '${MIDDLE_SERVER_HOST_ALIAS}' SSH 설정을 읽을 수 없습니다."
        exit 1
    fi

    current_hostname=$(ssh_config_value "$current_dump" "hostname")
    current_user=$(ssh_config_value "$current_dump" "user")
    current_port=$(ssh_config_value "$current_dump" "port")
    current_identity=$(ssh_config_value "$current_dump" "identityfile")

    if [ "$current_hostname" = "$ADMIN_HOSTNAME" ] &&
       [ "$current_user" = "$MIDDLE_SERVER_TUNNEL_USER" ] &&
       [ "$current_port" = "$ADMIN_PORT" ] &&
       [ "$current_identity" = "$USER_TUNNEL_KEY" ]; then
        echo "정보: SSH 설정 파일의 '${MIDDLE_SERVER_HOST_ALIAS}' 호스트 설정이 현재 설정과 일치합니다."
        return
    fi

    echo "오류: SSH 설정 파일에 '${MIDDLE_SERVER_HOST_ALIAS}' 호스트가 이미 있지만 현재 설정과 다릅니다."
    echo "      기존값: HostName=${current_hostname}, User=${current_user}, Port=${current_port}, IdentityFile=${current_identity}"
    echo "      기대값: HostName=${ADMIN_HOSTNAME}, User=${MIDDLE_SERVER_TUNNEL_USER}, Port=${ADMIN_PORT}, IdentityFile=${USER_TUNNEL_KEY}"
    echo "해결: '${USER_SSH_CONFIG}'에서 '${MIDDLE_SERVER_HOST_ALIAS}' Host 블록을 수정하거나 제거한 뒤 다시 실행하세요."
    exit 1
}

echo "=== 역방향 SSH 터널 자동 설정 스크립트 ==="
echo "정보: 터널 서비스는 '${SERVICE_USER}' 사용자의 권한으로 설정됩니다."

# 1. 설정 파일 로드
if [ ! -f "$CONFIG_FILE" ]; then
    echo "오류: 'config/tunnel.conf' 파일이 없습니다. README를 참고하여 생성하세요."
    exit 1
fi
source "$CONFIG_FILE"
validate_required_config

# ==============================================================================
# [단계 1/7] 터널 전용 SSH 키 확인 및 자동 생성
# ==============================================================================
echo
echo "--- [단계 1/7] 터널 전용 SSH 키 확인 및 생성 ---"
run_as_service_user mkdir -p "${USER_SSH_DIR}"
run_as_service_user chmod 700 "${USER_SSH_DIR}"
if [ ! -f "$USER_TUNNEL_KEY" ]; then
    echo "정보: 터널 전용 키(${USER_TUNNEL_KEY})가 없어 새로 생성합니다..."
    run_as_service_user ssh-keygen -t ed25519 -f "$USER_TUNNEL_KEY" -N "" -C "reverse-tunnel-key for ${SERVICE_USER}"
    echo "✅ 터널 전용 키를 성공적으로 생성했습니다."
else
    echo "정보: 터널 전용 키가 이미 존재합니다."
fi
PUBLIC_KEY_CONTENT=$(run_as_service_user cat "${USER_TUNNEL_KEY}.pub")
if ! [[ "$PUBLIC_KEY_CONTENT" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)[[:space:]][A-Za-z0-9+/=]+([[:space:]][A-Za-z0-9@._+=,:/ -]+)?$ ]]; then
    echo "오류: 터널 전용 공개키 형식이 올바르지 않습니다: ${USER_TUNNEL_KEY}.pub"
    exit 1
fi
PUBLIC_KEY_ESCAPED=$(printf '%q' "$PUBLIC_KEY_CONTENT")

# ==============================================================================
# [단계 2/7] 관리자 별칭에서 정보 역추출 및 터널용 config 자동 생성
# ==============================================================================
echo
echo "--- [단계 2/7] SSH 설정 파일 자동 구성 ---"
read -r -p "키 등록에 사용할 Middle Server의 '관리자 접속용 별칭(Host)'을 입력하세요: " ADMIN_HOST_ALIAS

if ! [[ "$ADMIN_HOST_ALIAS" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "오류: 관리자 접속용 별칭이 유효하지 않습니다."
    exit 1
fi

echo "정보: '${ADMIN_HOST_ALIAS}' 별칭의 설정을 분석하여 터널용 설정을 생성합니다..."
# ssh -G 옵션으로 관리자 별칭의 설정값을 파싱
if ! SSH_CONFIG_DUMP=$(run_as_service_user ssh -G "${ADMIN_HOST_ALIAS}"); then
    echo "오류: '${ADMIN_HOST_ALIAS}' 별칭의 SSH 설정을 읽을 수 없습니다."
    exit 1
fi
ADMIN_HOSTNAME=$(printf '%s\n' "$SSH_CONFIG_DUMP" | awk '/^hostname / { print $2 }')
ADMIN_PORT=$(printf '%s\n' "$SSH_CONFIG_DUMP" | awk '/^port / { print $2 }')

if [ -z "$ADMIN_HOSTNAME" ] || [ -z "$ADMIN_PORT" ]; then
    echo "오류: '${ADMIN_HOST_ALIAS}' 별칭에 대한 HostName 또는 Port 설정을 찾을 수 없습니다. '${USER_SSH_CONFIG}' 파일을 확인하세요."
    exit 1
fi
if ! validate_port "$ADMIN_PORT"; then
    echo "오류: '${ADMIN_HOST_ALIAS}' 별칭의 Port 값이 유효하지 않습니다: ${ADMIN_PORT}"
    exit 1
fi
echo "-> 분석 완료: HostName=${ADMIN_HOSTNAME}, Port=${ADMIN_PORT}"

# 파싱한 정보로 터널 접속용 Host 블록 생성
SSH_CONFIG_BLOCK=$(cat <<EOF
# Added by reverse-tunnel setup script
Host ${MIDDLE_SERVER_HOST_ALIAS}
  HostName ${ADMIN_HOSTNAME}
  User ${MIDDLE_SERVER_TUNNEL_USER}
  Port ${ADMIN_PORT}
  IdentityFile ${USER_TUNNEL_KEY}
EOF
)
# 파일에 해당 Host 설정이 이미 있는지 확인 후 추가
if ssh_host_exists "$MIDDLE_SERVER_HOST_ALIAS"; then
    validate_existing_tunnel_host
else
    echo "정보: SSH 설정 파일에 '${MIDDLE_SERVER_HOST_ALIAS}' 호스트 설정을 추가합니다..."
    run_as_service_user touch "${USER_SSH_CONFIG}" # 파일이 없을 경우 대비
    printf '\n%s\n' "$SSH_CONFIG_BLOCK" | run_as_service_user tee -a "${USER_SSH_CONFIG}" > /dev/null
    run_as_service_user chmod 600 "${USER_SSH_CONFIG}"
    echo "✅ SSH 설정 파일을 성공적으로 업데이트했습니다."
fi

# ==============================================================================
# [단계 3/7] 관리자 별칭을 통해 키 자동 등록
# ==============================================================================
echo
echo "--- [단계 3/7] SSH 키 자동 등록 ---"
REMOTE_COMMANDS=$(cat <<EOF
    set -e;
    echo "--- [Middle Server] 키 등록 작업을 시작합니다 ---";
    sudo mkdir -p /home/${MIDDLE_SERVER_TUNNEL_USER}/.ssh;
    sudo touch /home/${MIDDLE_SERVER_TUNNEL_USER}/.ssh/authorized_keys;
    if sudo grep -qF -- ${PUBLIC_KEY_ESCAPED} /home/${MIDDLE_SERVER_TUNNEL_USER}/.ssh/authorized_keys; then
        echo "--- [Middle Server] 키가 이미 존재하여 추가하지 않았습니다.";
    else
        printf '%s\n' ${PUBLIC_KEY_ESCAPED} | sudo tee -a /home/${MIDDLE_SERVER_TUNNEL_USER}/.ssh/authorized_keys > /dev/null;
        echo "--- [Middle Server] 새로운 키를 추가했습니다.";
    fi;
    sudo chmod 700 /home/${MIDDLE_SERVER_TUNNEL_USER}/.ssh;
    sudo chmod 600 /home/${MIDDLE_SERVER_TUNNEL_USER}/.ssh/authorized_keys;
    sudo chown -R ${MIDDLE_SERVER_TUNNEL_USER}:${MIDDLE_SERVER_TUNNEL_USER} /home/${MIDDLE_SERVER_TUNNEL_USER}/.ssh;
    echo "--- [Middle Server] 키 등록 및 소유권 설정 작업 완료 ---";
EOF
)

echo -n "정보: '${ADMIN_HOST_ALIAS}' 별칭으로 비밀번호 없는 접속을 시도합니다... "
if run_as_service_user ssh -F "${USER_SSH_CONFIG}" -T -o "PasswordAuthentication=no" -o "ConnectTimeout=5" "${ADMIN_HOST_ALIAS}" 'exit' &>/dev/null; then
    echo "성공!"
    run_as_service_user ssh -F "${USER_SSH_CONFIG}" -T "${ADMIN_HOST_ALIAS}" "${REMOTE_COMMANDS}"
else
    echo "실패. 대화형 모드로 전환합니다."
    echo "----------------------------------------------------------------------"
    echo "잠시 후 Middle Server(${ADMIN_HOST_ALIAS})에 접속하기 위한 비밀번호나 암호를 물어볼 수 있습니다."
    echo "----------------------------------------------------------------------"
    run_as_service_user ssh -F "${USER_SSH_CONFIG}" -T "${ADMIN_HOST_ALIAS}" "${REMOTE_COMMANDS}"
fi
echo "✅ SSH 키 자동 등록이 완료되었습니다."

# ==============================================================================
# [단계 4/7] 터널 계정 접속 검증
# ==============================================================================
echo
echo -n "--- [단계 4/7] 터널 계정 접속 검증... "
if run_as_service_user ssh -F "${USER_SSH_CONFIG}" -T -o "PasswordAuthentication=no" -o "ConnectTimeout=5" "${MIDDLE_SERVER_HOST_ALIAS}" 'exit' &>/dev/null; then
    echo "성공!"
else
    echo "실패!"
    echo "해결: 이전 단계에서 오류가 없었는지, '${MIDDLE_SERVER_HOST_ALIAS}'에 대한 SSH 설정을 다시 확인하세요."
    exit 1
fi

# ==============================================================================
# 나머지 설치 과정
# ==============================================================================
echo
echo "--- [단계 5/7] 의존성 패키지(autossh) 설치..."
DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update > /dev/null
DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y autossh
echo "--- [단계 6/7] 관련 파일 복사 및 권한 설정..."
mkdir -p "${INSTALL_DIR}/config"
mkdir -p "${INSTALL_DIR}/scripts"
cp "$CONFIG_FILE" "${INSTALL_DIR}/config/"
cp "${PROJECT_ROOT}/scripts/start-tunnel.sh" "${INSTALL_DIR}/scripts/"
cp "${PROJECT_ROOT}/scripts/healthcheck.sh" "${INSTALL_DIR}/scripts/"
chmod +x "${INSTALL_DIR}/scripts/start-tunnel.sh"
chmod +x "${INSTALL_DIR}/scripts/healthcheck.sh"
chown -R "${SERVICE_USER}:${SERVICE_USER}" "${INSTALL_DIR}"
echo "--- [단계 7/7] Systemd 서비스 등록 및 시작..."
sed "s/__PLACEHOLDER_USER__/${SERVICE_USER}/g" "${PROJECT_ROOT}/systemd/reverse-tunnel.service" > /etc/systemd/system/reverse-tunnel.service
chmod 644 /etc/systemd/system/reverse-tunnel.service
systemctl daemon-reload
systemctl enable reverse-tunnel.service
systemctl restart reverse-tunnel.service
sleep 3
systemctl status reverse-tunnel.service --no-pager -n 20

echo "============================================="
echo "✅ 모든 설정이 성공적으로 완료되었습니다."
echo "============================================="
