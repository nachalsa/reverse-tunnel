#!/bin/bash

# ==============================================================================
# Middle Server 설정 제거 스크립트
# ==============================================================================
# 사용법:
# 1. 이 스크립트를 middle-server의 'scripts' 디렉토리에 위치시킵니다.
# 2. sudo 권한으로 실행합니다: sudo ./uninstall.sh
# ==============================================================================

# --- 스크립트 기본 설정 ---
set -euo pipefail

# --- 사전 검증 ---
if [ "$(id -u)" -ne 0 ]; then
    echo "오류: 이 스크립트는 root 권한으로 실행해야 합니다. (sudo ./uninstall.sh)"
    exit 1
fi

# --- 변수 정의 ---
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
CONFIG_FILE="${SCRIPT_DIR}/../config/middle.conf"
SSHD_CONFIG_FILE="/etc/ssh/sshd_config"
SSHD_CONFIG_BEGIN_MARKER="# BEGIN reverse-tunnel managed block"
SSHD_CONFIG_END_MARKER="# END reverse-tunnel managed block"

restart_ssh_service() {
    if systemctl list-unit-files ssh.service 2>/dev/null | grep -q '^ssh.service'; then
        systemctl restart ssh
    elif systemctl list-unit-files sshd.service 2>/dev/null | grep -q '^sshd.service'; then
        systemctl restart sshd
    else
        systemctl restart sshd
    fi
}

# --- 메인 로직 ---
echo "=== Middle Server 설정 제거 시작 ==="

# 1. 설정 파일 로드
if [ ! -f "$CONFIG_FILE" ]; then
    echo "경고: 설정 파일(${CONFIG_FILE})이 없습니다. 일부 작업이 실패할 수 있습니다."
    # 설정 파일이 없어도 기본값으로 시도할 수 있도록 변수 선언
    TUNNEL_USER="tunnel"
    TUNNEL_PORTS_TO_OPEN=""
    echo "기본값으로 제거를 시도합니다: 사용자=${TUNNEL_USER}, 포트=${TUNNEL_PORTS_TO_OPEN}"
else
    source "$CONFIG_FILE"
    echo "정보: 설정 파일(${CONFIG_FILE})을 성공적으로 읽었습니다."
fi
TUNNEL_USER="${TUNNEL_USER:-tunnel}"
TUNNEL_PORTS_TO_OPEN="${TUNNEL_PORTS_TO_OPEN:-}"

# 2. 방화벽 포트 규칙 삭제 (ufw)
echo "단계 1/3: 방화벽(ufw)에서 터널 포트 규칙을 삭제합니다..."
if ! command -v ufw &> /dev/null; then
    echo "경고: ufw가 설치되어 있지 않습니다. 방화벽 설정을 건너뜁니다."
else
    if [ -z "$TUNNEL_PORTS_TO_OPEN" ]; then
        echo "-> 삭제할 터널 포트 목록이 없습니다. 건너뜁니다."
    else
        for port in $TUNNEL_PORTS_TO_OPEN; do
            if ufw delete allow "${port}/tcp" > /dev/null 2>&1; then
                 echo "-> 포트 ${port}/tcp 규칙을 삭제했습니다."
            else
                 echo "-> 포트 ${port}/tcp 규칙이 없거나 삭제할 수 없습니다. 건너뜁니다."
            fi
        done
    fi
fi

# 3. SSH 서버 설정 원복 (GatewayPorts)
echo -n "단계 2/3: SSH 설정 파일(${SSHD_CONFIG_FILE})에서 'GatewayPorts yes' 관련 설정을 제거합니다... "
if grep -q "^${SSHD_CONFIG_BEGIN_MARKER}$" "$SSHD_CONFIG_FILE"; then
    SSHD_CONFIG_BACKUP="${SSHD_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$SSHD_CONFIG_FILE" "$SSHD_CONFIG_BACKUP"
    sed -i "/^${SSHD_CONFIG_BEGIN_MARKER}$/,/^${SSHD_CONFIG_END_MARKER}$/d" "$SSHD_CONFIG_FILE"

    if ! sshd -t -f "$SSHD_CONFIG_FILE"; then
        cp "$SSHD_CONFIG_BACKUP" "$SSHD_CONFIG_FILE"
        echo "실패! sshd 설정 검증에 실패하여 백업으로 복구했습니다: ${SSHD_CONFIG_BACKUP}"
        exit 1
    fi

    restart_ssh_service
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
