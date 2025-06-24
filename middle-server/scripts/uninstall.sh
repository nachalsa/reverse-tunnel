#!/bin/bash

# ==============================================================================
# Middle Server 설정 제거 스크립트
# ==============================================================================
# 사용법:
# 1. 이 스크립트를 middle-server의 'scripts' 디렉토리에 위치시킵니다.
# 2. sudo 권한으로 실행합니다: sudo ./uninstall.sh
# ==============================================================================

# --- 스크립트 기본 설정 ---
set -e
set -o pipefail

# --- 사전 검증 ---
if [ "$(id -u)" -ne 0 ]; then
    echo "오류: 이 스크립트는 root 권한으로 실행해야 합니다. (sudo ./uninstall.sh)"
    exit 1
fi

# --- 변수 정의 ---
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
CONFIG_FILE="${SCRIPT_DIR}/../config/middle.conf"
SSHD_CONFIG_FILE="/etc/ssh/sshd_config"

# --- 메인 로직 ---
echo "=== Middle Server 설정 제거 시작 ==="

# 1. 설정 파일 로드
if [ ! -f "$CONFIG_FILE" ]; then
    echo "경고: 설정 파일(${CONFIG_FILE})이 없습니다. 일부 작업이 실패할 수 있습니다."
    # 설정 파일이 없어도 기본값으로 시도할 수 있도록 변수 선언
    TUNNEL_USER="tunnel"
    TUNNEL_PORTS_TO_OPEN="2222 8080"
    echo "기본값으로 제거를 시도합니다: 사용자=${TUNNEL_USER}, 포트=${TUNNEL_PORTS_TO_OPEN}"
else
    source "$CONFIG_FILE"
    echo "정보: 설정 파일(${CONFIG_FILE})을 성공적으로 읽었습니다."
fi

# 2. 방화벽 포트 규칙 삭제 (ufw)
echo "단계 1/3: 방화벽(ufw)에서 터널 포트 규칙을 삭제합니다..."
if ! command -v ufw &> /dev/null; then
    echo "경고: ufw가 설치되어 있지 않습니다. 방화벽 설정을 건너뜁니다."
else
    for port in $TUNNEL_PORTS_TO_OPEN; do
        if ufw status | grep -qw "${port}/tcp"; then
             ufw delete allow "${port}/tcp" > /dev/null
             echo "-> 포트 ${port}/tcp 규칙을 삭제했습니다."
        else
             echo "-> 포트 ${port}/tcp 규칙이 이미 없습니다. 건너뜁니다."
        fi
    done
fi

# 3. SSH 서버 설정 원복 (GatewayPorts)
echo -n "단계 2/3: SSH 설정 파일(${SSHD_CONFIG_FILE})에서 'GatewayPorts yes' 관련 설정을 제거합니다... "
if grep -q "# Reverse Tunneling을 위해 추가된 설정" "$SSHD_CONFIG_FILE"; then
    # 만일의 사태를 대비해 백업
    cp "$SSHD_CONFIG_FILE" "${SSHD_CONFIG_FILE}.bak.$(date +%F-%T)"
    # sed를 사용하여 추가했던 주석과 설정 라인을 삭제
    sed -i '/# Reverse Tunneling을 위해 추가된 설정 (by provision.sh)/d' "$SSHD_CONFIG_FILE"
    sed -i '/^GatewayPorts yes$/d' "$SSHD_CONFIG_FILE"
    systemctl restart sshd
    echo "성공! (sshd 재시작됨)"
else
    echo "이미 제거되었거나 설정된 적이 없습니다. 건너뜁니다."
fi

# 4. 터널 전용 사용자 삭제
echo -n "단계 3/3: '${TUNNEL_USER}' 사용자를 삭제합니다... "
if id "${TUNNEL_USER}" &>/dev/null; then
    deluser --remove-home "${TUNNEL_USER}" > /dev/null
    echo "성공!"
else
    echo "이미 존재하지 않습니다. 건너뜁니다."
fi


echo "============================================="
echo "✅ Middle Server 설정이 성공적으로 제거되었습니다."
echo "============================================="