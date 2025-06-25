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
USER_SSH_CONFIG="${USER_HOME}/.ssh/config"
USER_PUBLIC_KEY="${USER_HOME}/.ssh/id_ed25519_tunnel.pub"

echo "=== 역방향 SSH 터널 자동 설정 스크립트 ==="
echo "정보: 터널 서비스는 '${SERVICE_USER}' 사용자의 권한으로 설정됩니다."

# 1. 설정 파일 로드
if [ ! -f "$CONFIG_FILE" ]; then
    echo "오류: 'config/tunnel.conf' 파일이 없습니다."
    exit 1
fi
source "$CONFIG_FILE"

# 2. SSH 공개키 파일 확인
if [ ! -f "$USER_PUBLIC_KEY" ]; then
    echo "오류: SSH 공개키 파일(${USER_PUBLIC_KEY})을 찾을 수 없습니다."
    exit 1
fi
PUBLIC_KEY_CONTENT=$(cat "${USER_PUBLIC_KEY}")

# ==============================================================================
# [최종 진화] Middle Server 관리자 접속용 "별칭"을 입력받아 키 자동 등록
# ==============================================================================
echo
echo "--- [단계 1/6] SSH 키 자동 등록 ---"
echo "SSH 키를 Middle Server에 자동으로 등록하기 위해, Middle Server의 '관리자 계정 접속용 별칭'이 필요합니다."
echo "이 별칭은 '${USER_SSH_CONFIG}' 파일에 설정되어 있어야 합니다."
read -p "Middle Server 관리자 접속용 별칭(Host)을 입력하세요 (예: my-vps-admin): " ADMIN_HOST_ALIAS

if [ -z "$ADMIN_HOST_ALIAS" ]; then
    echo "오류: 관리자 접속용 별칭이 입력되지 않았습니다. 스크립트를 종료합니다."
    exit 1
fi

# Middle Server에서 실행할 전체 명령어 블록 정의
REMOTE_COMMANDS=$(cat <<EOF
    echo "--- [Middle Server] 키 등록 작업을 시작합니다 ---";
    sudo mkdir -p /home/${MIDDLE_SERVER_USER}/.ssh;
    # 키가 이미 있는지 확인하여 중복 추가 방지
    if sudo grep -qF "${PUBLIC_KEY_CONTENT}" /home/${MIDDLE_SERVER_USER}/.ssh/authorized_keys; then
        echo "--- [Middle Server] 키가 이미 존재하여 추가하지 않았습니다.";
    else
        sudo sh -c 'echo "${PUBLIC_KEY_CONTENT}" >> /home/${MIDDLE_SERVER_USER}/.ssh/authorized_keys';
        echo "--- [Middle Server] 새로운 키를 추가했습니다.";
    fi;
    sudo chmod 700 /home/${MIDDLE_SERVER_USER}/.ssh;
    sudo chmod 600 /home/${MIDDLE_SERVER_USER}/.ssh/authorized_keys;
    # 소유권 변경
    sudo chown -R ${MIDDLE_SERVER_USER}:${MIDDLE_SERVER_USER} /home/${MIDDLE_SERVER_USER}/.ssh;
    echo "--- [Middle Server] 키 등록 및 소유권 설정 작업 완료 ---";
EOF
)

# 먼저 비밀번호 없이 접속을 시도
echo -n "정보: '${ADMIN_HOST_ALIAS}' 별칭으로 비밀번호 없는 접속을 시도합니다... "
if sudo -u ${SERVICE_USER} ssh -F "${USER_SSH_CONFIG}" -T -o "PasswordAuthentication=no" -o "ConnectTimeout=5" "${ADMIN_HOST_ALIAS}" 'exit' &>/dev/null; then
    echo "성공!"
    # 비밀번호 없이 바로 원격 명령어 실행
    sudo -u ${SERVICE_USER} ssh -F "${USER_SSH_CONFIG}" -T "${ADMIN_HOST_ALIAS}" "${REMOTE_COMMANDS}"
else
    echo "실패. 대화형 모드로 전환합니다."
    echo "----------------------------------------------------------------------"
    echo "잠시 후 Middle Server(${ADMIN_HOST_ALIAS})에 접속하기 위한 비밀번호나 암호를 물어볼 수 있습니다."
    echo "----------------------------------------------------------------------"
    # 비밀번호 입력을 허용하여 원격 명령어 실행
    sudo -u ${SERVICE_USER} ssh -F "${USER_SSH_CONFIG}" -T "${ADMIN_HOST_ALIAS}" "${REMOTE_COMMANDS}"
fi

echo "✅ SSH 키 자동 등록이 완료되었습니다."
echo

# 3. 키 기반 접속 검증
echo -n "--- [단계 2/6] 키 기반 접속 검증... "
if sudo -u ${SERVICE_USER} ssh -F "${USER_SSH_CONFIG}" -T -o "PasswordAuthentication=no" -o "ConnectTimeout=5" "${MIDDLE_SERVER_USER}@${MIDDLE_SERVER_IP}" 'exit' &>/dev/null; then
    echo "성공!"
else
    echo "실패!"
    echo "해결: 이전 단계에서 오류가 없었는지, ~/.ssh/config 파일 설정을 다시 확인하세요."
    echo "-u ${SERVICE_USER} ssh -F ${USER_SSH_CONFIG} -T -o PasswordAuthentication=no -o ConnectTimeout=5  ${MIDDLE_SERVER_USER}@${MIDDLE_SERVER_IP}exit &>/dev/null; then"
    exit 1
fi

echo "--- [단계 3/6] 의존성 패키지(autossh) 설치..."
apt-get update > /dev/null
apt-get install -y autossh
echo "--- [단계 4/6] 관련 파일 복사..."
mkdir -p "${INSTALL_DIR}/config"
mkdir -p "${INSTALL_DIR}/scripts"
cp "$CONFIG_FILE" "${INSTALL_DIR}/config/"
cp "${PROJECT_ROOT}/scripts/start-tunnel.sh" "${INSTALL_DIR}/scripts/"
echo "--- [단계 5/6] 권한 설정..."
chmod +x "${INSTALL_DIR}/scripts/start-tunnel.sh"
chown -R ${SERVICE_USER}:${SERVICE_USER} ${INSTALL_DIR}
echo "--- [단계 6/6] Systemd 서비스 등록 및 시작..."
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