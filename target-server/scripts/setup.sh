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
USER_PUBLIC_KEY="${USER_HOME}/.ssh/id_ed25519.pub"

echo "=== 역방향 SSH 터널 자동 설정 스크립트 ==="
echo "정보: 터널 서비스는 '${SERVICE_USER}' 사용자의 권한으로 설정됩니다."

# 1. 설정 파일 로드 (기존 변수명 사용)
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
# [핵심] Middle Server 관리자 정보를 직접 입력받아 SSH 키 자동 등록
# ==============================================================================
echo
echo "--- [단계 1/6] SSH 키 자동 등록 ---"
echo "SSH 키를 Middle Server에 자동으로 등록하기 위해, Middle Server의 '관리자 계정' 정보가 필요합니다."
read -p "Middle Server의 관리자 사용자 이름을 입력하세요 (예: ubuntu, ec2-user, root): " ADMIN_USER_FOR_KEY_COPY

if [ -z "$ADMIN_USER_FOR_KEY_COPY" ]; then
    echo "오류: 관리자 사용자 이름이 입력되지 않았습니다. 스크립트를 종료합니다."
    exit 1
fi

echo "----------------------------------------------------------------------"
# MIDDLE_SERVER_IP는 이제 'pitunnel' 같은 별칭일 수 있습니다.
echo "잠시 후 Middle Server(${MIDDLE_SERVER_IP})의 '${ADMIN_USER_FOR_KEY_COPY}' 사용자 비밀번호나 암호를 물어볼 수 있습니다."
echo "----------------------------------------------------------------------"

# 히어 독(Here Document)을 사용하여 원격 명령 실행
# MIDDLE_SERVER_USER는 tunnel.conf에서 읽어온 터널용 사용자 이름입니다.
sudo -u ${SERVICE_USER} ssh -F "${USER_SSH_CONFIG}" -T "${ADMIN_USER_FOR_KEY_COPY}@${MIDDLE_SERVER_IP}" << EOF
    echo "--- [Middle Server] 키 등록 작업을 시작합니다 ---"
    sudo mkdir -p /home/${MIDDLE_SERVER_USER}/.ssh
    if ! sudo grep -qF "${PUBLIC_KEY_CONTENT}" /home/${MIDDLE_SERVER_USER}/.ssh/authorized_keys; then
        sudo sh -c 'echo "${PUBLIC_KEY_CONTENT}" >> /home/${MIDDLE_SERVER_USER}/.ssh/authorized_keys'
        echo "--- [Middle Server] 새로운 키를 추가했습니다."
    else
        echo "--- [Middle Server] 키가 이미 존재하여 추가하지 않았습니다."
    fi
    sudo chmod 700 /home/${MIDDLE_SERVER_USER}/.ssh
    sudo chmod 600 /home/${MIDDLE_SERVER_USER}/.ssh/authorized_keys
    echo "--- [Middle Server] 키 등록 작업 완료 ---"
EOF
echo "✅ SSH 키 자동 등록이 완료되었습니다."
echo

# 3. 키 기반 접속 검증
echo -n "--- [단계 2/6] 키 기반 접속 검증... "
# 이제 터널 사용자로 접속 테스트 (tunnel.conf의 변수 사용)
if sudo -u ${SERVICE_USER} ssh -F "${USER_SSH_CONFIG}" -T -o "PasswordAuthentication=no" -o "ConnectTimeout=5" "${MIDDLE_SERVER_USER}@${MIDDLE_SERVER_IP}" 'exit' &>/dev/null; then
    echo "성공!"
else
    echo "실패!"
    echo "해결: 이전 단계에서 오류가 없었는지, ~/.ssh/config 파일 설정을 다시 확인하세요."
    exit 1
fi

# 3. 의존성 설치
echo "단계 3/6: 의존성 패키지(autossh)를 설치합니다..."
apt-get update > /dev/null
apt-get install -y autossh

# 4. 파일 설치
echo "단계 4/6: 관련 파일을 ${INSTALL_DIR} 디렉토리로 복사합니다..."
mkdir -p "${INSTALL_DIR}/config"
mkdir -p "${INSTALL_DIR}/scripts"
cp "$CONFIG_FILE" "${INSTALL_DIR}/config/"
cp "${PROJECT_ROOT}/scripts/start-tunnel.sh" "${INSTALL_DIR}/scripts/"

# 5. 권한 설정
echo "단계 5/6: 설치된 파일의 권한을 설정합니다..."
chmod +x "${INSTALL_DIR}/scripts/start-tunnel.sh"
chown -R ${SERVICE_USER}:${SERVICE_USER} ${INSTALL_DIR}

# 6. Systemd 서비스 파일 동적 생성 및 등록
echo "단계 6/6: Systemd 서비스를 등록하고 시작합니다..."
sed "s/__PLACEHOLDER_USER__/${SERVICE_USER}/g" "$SERVICE_FILE_TEMPLATE" > "$SERVICE_FILE_TARGET"
chmod 644 "$SERVICE_FILE_TARGET"
systemctl daemon-reload
systemctl enable reverse-tunnel.service
systemctl restart reverse-tunnel.service
sleep 3
systemctl status reverse-tunnel.service --no-pager -n 20

echo "============================================="
echo "✅ 모든 설정이 성공적으로 완료되었습니다."
echo "============================================="