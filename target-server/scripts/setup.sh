#!/bin/bash

# --- 스크립트 기본 설정 ---
set -e
set -o pipefail

# --- 사전 검증 ---
if [ "$(id -u)" -ne 0 ]; then
    echo "오류: 이 스크립트는 root 권한으로 실행해야 합니다. (sudo ./setup.sh)"
    exit 1
fi

if [ -z "$SUDO_USER" ]; then
    echo "오류: root로 직접 로그인하여 실행하지 마십시오."
    echo "      터널을 실행할 일반 사용자 계정에서 'sudo ./setup.sh' 형태로 실행하세요."
    exit 1
fi
SERVICE_USER=$SUDO_USER

# --- 변수 정의 ---
PROJECT_ROOT=$(dirname "$(readlink -f "$0")")/..
INSTALL_DIR="/opt/reverse-tunnel"
CONFIG_FILE="${PROJECT_ROOT}/config/tunnel.conf"
SERVICE_FILE_TEMPLATE="${PROJECT_ROOT}/systemd/reverse-tunnel.service"
SERVICE_FILE_TARGET="/etc/systemd/system/reverse-tunnel.service"
USER_HOME=$(eval echo ~$SERVICE_USER)

# --- 메인 로직 ---
echo "=== 역방향 SSH 터널 자동 설정 스크립트 ==="
echo "정보: 터널 서비스는 '${SERVICE_USER}' 사용자의 권한으로 설정됩니다."

# 1. 설정 파일 존재 여부 확인
# ... (이전과 동일, 생략)
source "$CONFIG_FILE"

# 2. SSH 연결 자동 검증
# ... (이전과 동일, 생략)

# 3. 의존성 설치
echo "단계 1/5: 의존성 패키지(autossh)를 설치합니다..."
apt-get update > /dev/null
apt-get install -y autossh

# 4. 파일 설치
echo "단계 2/5: 관련 파일을 ${INSTALL_DIR} 디렉토리로 복사합니다..."
mkdir -p "${INSTALL_DIR}/config"
mkdir -p "${INSTALL_DIR}/scripts"

cp "$CONFIG_FILE" "${INSTALL_DIR}/config/"
cp "${PROJECT_ROOT}/scripts/start-tunnel.sh" "${INSTALL_DIR}/scripts/"

# 5. 권한 설정 (명확화)
echo "단계 3/5: 설치된 파일의 권한을 설정합니다..."
# 실행 스크립트에 실행 권한 부여
chmod +x "${INSTALL_DIR}/scripts/start-tunnel.sh"
# 설치된 모든 파일의 소유자를 서비스 실행 사용자로 변경
chown -R ${SERVICE_USER}:${SERVICE_USER} ${INSTALL_DIR}
echo "-> '${INSTALL_DIR}' 디렉토리의 소유자를 '${SERVICE_USER}'로 변경했습니다."

# 6. Systemd 서비스 파일 동적 생성 및 등록
echo "단계 4/5: Systemd 서비스 파일을 동적으로 생성하고 등록합니다..."
# sed를 사용하여 플레이스홀더를 실제 사용자 이름으로 교체하고, 최종 위치에 파일을 생성
sed "s/__PLACEHOLDER_USER__/${SERVICE_USER}/g" "$SERVICE_FILE_TEMPLATE" > "$SERVICE_FILE_TARGET"
# 서비스 파일에 표준 권한(644)을 명시적으로 부여
chmod 644 "$SERVICE_FILE_TARGET"
echo "-> '${SERVICE_FILE_TARGET}' 파일이 생성되었습니다 (권한: 644)."

systemctl daemon-reload
systemctl enable reverse-tunnel.service
systemctl restart reverse-tunnel.service

# 7. 최종 상태 확인
echo "단계 5/5: 서비스가 정상적으로 실행되었는지 확인합니다..."
sleep 3
systemctl status reverse-tunnel.service --no-pager -n 20

echo "============================================="
echo "✅ 설정이 성공적으로 완료되었습니다."
echo "============================================="