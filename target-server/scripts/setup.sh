#!/bin/bash
set -e
set -o pipefail

# --- 사전 검증 및 변수 정의 ---
if [ "$(id -u)" -ne 0 ]; then
    echo "오류: 이 스크립트는 root 권한으로 실행해야 합니다. (sudo ./setup.sh)"
    exit 1
fi
if [ -z "$SUDO_USER" ]; then
    echo "오류: root로 직접 로그인하지 마십시오. 일반 사용자 계정에서 'sudo ./setup.sh'를 실행하세요."
    exit 1
fi
SERVICE_USER=$SUDO_USER

PROJECT_ROOT=$(dirname "$(readlink -f "$0")")/..
INSTALL_DIR="/opt/reverse-tunnel"
CONFIG_FILE="${PROJECT_ROOT}/config/tunnel.conf"
USER_HOME=$(eval echo ~$SERVICE_USER)
USER_SSH_DIR="${USER_HOME}/.ssh"
USER_SSH_CONFIG="${USER_SSH_DIR}/config"
USER_TUNNEL_KEY="${USER_SSH_DIR}/id_ed25519_tunnel"

echo "=== 역방향 SSH 터널 자동 설정 스크립트 ==="
echo "정보: 터널 서비스는 '${SERVICE_USER}' 사용자의 권한으로 설정됩니다."

# 1. 설정 파일 로드
if [ ! -f "$CONFIG_FILE" ]; then
    echo "오류: 'config/tunnel.conf' 파일이 없습니다. README를 참고하여 생성하세요."
    exit 1
fi
source "$CONFIG_FILE"

# ==============================================================================
# [단계 1/7] 터널 전용 SSH 키 확인 및 자동 생성
# ==============================================================================
echo
echo "--- [단계 1/7] 터널 전용 SSH 키 확인 및 생성 ---"
sudo -u ${SERVICE_USER} mkdir -p "${USER_SSH_DIR}"
sudo -u ${SERVICE_USER} chmod 700 "${USER_SSH_DIR}"
if [ ! -f "$USER_TUNNEL_KEY" ]; then
    echo "정보: 터널 전용 키(${USER_TUNNEL_KEY})가 없어 새로 생성합니다..."
    sudo -u ${SERVICE_USER} ssh-keygen -t ed25519 -f "$USER_TUNNEL_KEY" -N "" -C "reverse-tunnel-key for ${SERVICE_USER}"
    echo "✅ 터널 전용 키를 성공적으로 생성했습니다."
else
    echo "정보: 터널 전용 키가 이미 존재합니다."
fi
PUBLIC_KEY_CONTENT=$(sudo -u ${SERVICE_USER} cat "${USER_TUNNEL_KEY}.pub")

# ==============================================================================
# [단계 2/7] 관리자 별칭에서 정보 역추출 및 터널용 config 자동 생성
# ==============================================================================
echo
echo "--- [단계 2/7] SSH 설정 파일 자동 구성 ---"
read -p "키 등록에 사용할 Middle Server의 '관리자 접속용 별칭(Host)'을 입력하세요: " ADMIN_HOST_ALIAS

if [ -z "$ADMIN_HOST_ALIAS" ]; then
    echo "오류: 관리자 접속용 별칭이 입력되지 않았습니다."
    exit 1
fi

echo "정보: '${ADMIN_HOST_ALIAS}' 별칭의 설정을 분석하여 터널용 설정을 생성합니다..."
# ssh -G 옵션으로 관리자 별칭의 설정값을 파싱
ADMIN_HOSTNAME=$(sudo -u ${SERVICE_USER} ssh -G "${ADMIN_HOST_ALIAS}" | awk '/^hostname / { print $2 }')
ADMIN_PORT=$(sudo -u ${SERVICE_USER} ssh -G "${ADMIN_HOST_ALIAS}" | awk '/^port / { print $2 }')

if [ -z "$ADMIN_HOSTNAME" ] || [ -z "$ADMIN_PORT" ]; then
    echo "오류: '${ADMIN_HOST_ALIAS}' 별칭에 대한 HostName 또는 Port 설정을 찾을 수 없습니다. '${USER_SSH_CONFIG}' 파일을 확인하세요."
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
if sudo -u ${SERVICE_USER} grep -q "Host ${MIDDLE_SERVER_HOST_ALIAS}" "${USER_SSH_CONFIG}" 2>/dev/null; then
    echo "정보: SSH 설정 파일에 '${MIDDLE_SERVER_HOST_ALIAS}' 호스트 설정이 이미 존재하여 건너뜁니다."
else
    echo "정보: SSH 설정 파일에 '${MIDDLE_SERVER_HOST_ALIAS}' 호스트 설정을 추가합니다..."
    sudo -u ${SERVICE_USER} touch "${USER_SSH_CONFIG}" # 파일이 없을 경우 대비
    sudo -u ${SERVICE_USER} bash -c "echo '' >> '${USER_SSH_CONFIG}'; echo '${SSH_CONFIG_BLOCK}' >> '${USER_SSH_CONFIG}'"
    sudo -u ${SERVICE_USER} chmod 600 "${USER_SSH_CONFIG}"
    echo "✅ SSH 설정 파일을 성공적으로 업데이트했습니다."
fi

# ==============================================================================
# [단계 3/7] 관리자 별칭을 통해 키 자동 등록
# ==============================================================================
echo
echo "--- [단계 3/7] SSH 키 자동 등록 ---"
REMOTE_COMMANDS=$(cat <<EOF
    echo "--- [Middle Server] 키 등록 작업을 시작합니다 ---";
    sudo mkdir -p /home/${MIDDLE_SERVER_TUNNEL_USER}/.ssh;
    if sudo grep -qF "${PUBLIC_KEY_CONTENT}" /home/${MIDDLE_SERVER_TUNNEL_USER}/.ssh/authorized_keys; then
        echo "--- [Middle Server] 키가 이미 존재하여 추가하지 않았습니다.";
    else
        sudo sh -c 'echo "${PUBLIC_KEY_CONTENT}" >> /home/${MIDDLE_SERVER_TUNNEL_USER}/.ssh/authorized_keys';
        echo "--- [Middle Server] 새로운 키를 추가했습니다.";
    fi;
    sudo chmod 700 /home/${MIDDLE_SERVER_TUNNEL_USER}/.ssh;
    sudo chmod 600 /home/${MIDDLE_SERVER_TUNNEL_USER}/.ssh/authorized_keys;
    sudo chown -R ${MIDDLE_SERVER_TUNNEL_USER}:${MIDDLE_SERVER_TUNNEL_USER} /home/${MIDDLE_SERVER_TUNNEL_USER}/.ssh;
    echo "--- [Middle Server] 키 등록 및 소유권 설정 작업 완료 ---";
EOF
)

echo -n "정보: '${ADMIN_HOST_ALIAS}' 별칭으로 비밀번호 없는 접속을 시도합니다... "
if sudo -u ${SERVICE_USER} ssh -F "${USER_SSH_CONFIG}" -T -o "PasswordAuthentication=no" -o "ConnectTimeout=5" "${ADMIN_HOST_ALIAS}" 'exit' &>/dev/null; then
    echo "성공!"
    sudo -u ${SERVICE_USER} ssh -F "${USER_SSH_CONFIG}" -T "${ADMIN_HOST_ALIAS}" "${REMOTE_COMMANDS}"
else
    echo "실패. 대화형 모드로 전환합니다."
    echo "----------------------------------------------------------------------"
    echo "잠시 후 Middle Server(${ADMIN_HOST_ALIAS})에 접속하기 위한 비밀번호나 암호를 물어볼 수 있습니다."
    echo "----------------------------------------------------------------------"
    sudo -u ${SERVICE_USER} ssh -F "${USER_SSH_CONFIG}" -T "${ADMIN_HOST_ALIAS}" "${REMOTE_COMMANDS}"
fi
echo "✅ SSH 키 자동 등록이 완료되었습니다."

# ==============================================================================
# [단계 4/7] 터널 계정 접속 검증
# ==============================================================================
echo
echo -n "--- [단계 4/7] 터널 계정 접속 검증... "
if sudo -u ${SERVICE_USER} ssh -F "${USER_SSH_CONFIG}" -T -o "PasswordAuthentication=no" -o "ConnectTimeout=5" "${MIDDLE_SERVER_HOST_ALIAS}" 'exit' &>/dev/null; then
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
apt-get update > /dev/null
apt-get install -y autossh
echo "--- [단계 6/7] 관련 파일 복사 및 권한 설정..."
mkdir -p "${INSTALL_DIR}/config"
mkdir -p "${INSTALL_DIR}/scripts"
cp "$CONFIG_FILE" "${INSTALL_DIR}/config/"
cp "${PROJECT_ROOT}/scripts/start-tunnel.sh" "${INSTALL_DIR}/scripts/"
chmod +x "${INSTALL_DIR}/scripts/start-tunnel.sh"
chown -R ${SERVICE_USER}:${SERVICE_USER} ${INSTALL_DIR}
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