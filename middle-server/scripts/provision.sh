#!/bin/bash

# ==============================================================================
# Middle Server 프로비저닝 스크립트 (설정 파일 기반)
# ==============================================================================
# 사용법:
# 1. ../config/middle.conf.example 파일을 ../config/middle.conf 로 복사합니다.
# 2. ../config/middle.conf 파일의 내용을 본인 환경에 맞게 수정합니다.
# 3. 이 스크립트를 sudo 권한으로 실행합니다: sudo ./provision.sh
# ==============================================================================

# --- 스크립트 기본 설정 ---
set -euo pipefail

# --- 사전 검증 ---
if [ "$(id -u)" -ne 0 ]; then
    echo "오류: 이 스크립트는 root 권한으로 실행해야 합니다. (sudo ./provision.sh)"
    exit 1
fi

# --- 변수 정의 ---
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
CONFIG_FILE="${SCRIPT_DIR}/../config/middle.conf"
SSHD_CONFIG_FILE="/etc/ssh/sshd_config"
SSHD_CONFIG_MARKER="# Reverse Tunneling을 위해 추가된 설정 (by provision.sh)"

restart_ssh_service() {
    if systemctl list-unit-files ssh.service 2>/dev/null | grep -q '^ssh.service'; then
        systemctl restart ssh
    elif systemctl list-unit-files sshd.service 2>/dev/null | grep -q '^sshd.service'; then
        systemctl restart sshd
    else
        systemctl restart sshd
    fi
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

detect_sshd_ports() {
    local ports
    ports=$(sshd -T 2>/dev/null | awk '/^port / {print $2}' | sort -n -u || true)
    if [ -z "$ports" ]; then
        ports="22"
    fi
    printf '%s\n' "$ports"
}

validate_required_config() {
    if [ -z "${TUNNEL_USER:-}" ]; then
        echo "오류: TUNNEL_USER 값이 설정되어 있지 않습니다."
        exit 1
    fi

    if ! [[ "$TUNNEL_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
        echo "오류: TUNNEL_USER 값('${TUNNEL_USER}')이 유효한 리눅스 사용자 이름 형식이 아닙니다."
        exit 1
    fi

    if [ -z "${TUNNEL_PORTS_TO_OPEN:-}" ]; then
        echo "오류: TUNNEL_PORTS_TO_OPEN 값이 설정되어 있지 않습니다."
        exit 1
    fi

    local port
    for port in $TUNNEL_PORTS_TO_OPEN; do
        if ! validate_port "$port"; then
            echo "오류: 유효하지 않은 포트 값입니다: ${port}"
            exit 1
        fi
    done
}

# --- 메인 로직 ---
echo "=== Middle Server 자동 설정 시작 ==="

# 1. 설정 파일 로드
if [ ! -f "$CONFIG_FILE" ]; then
    echo "오류: 설정 파일(${CONFIG_FILE})이 없습니다."
    echo "해결: middle.conf.example 파일을 middle.conf 로 복사하고 내용을 수정하세요."
    exit 1
fi
source "$CONFIG_FILE"
echo "정보: 설정 파일(${CONFIG_FILE})을 성공적으로 읽었습니다."
validate_required_config

# 2. 터널 전용 사용자 생성
echo -n "단계 1/3: '${TUNNEL_USER}' 사용자를 생성합니다... "
if id "${TUNNEL_USER}" &>/dev/null; then
    echo "이미 존재합니다. 건너뜁니다."
else
    # 비밀번호 로그인 비활성화 (SSH 키만 허용), 부가 정보 묻지 않음
    adduser --quiet --disabled-password --gecos "" "${TUNNEL_USER}"
    echo "성공!"
fi

# 3. SSH 서버 설정 (GatewayPorts)
echo -n "단계 2/3: SSH 설정 파일(${SSHD_CONFIG_FILE})에 'GatewayPorts yes'를 설정합니다... "
if grep -qE "^[[:space:]]*GatewayPorts[[:space:]]+yes" "$SSHD_CONFIG_FILE"; then
    echo "이미 설정되어 있습니다. 건너뜁니다."
else
    SSHD_CONFIG_BACKUP="${SSHD_CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$SSHD_CONFIG_FILE" "$SSHD_CONFIG_BACKUP"
    {
        echo ""
        echo "$SSHD_CONFIG_MARKER"
        echo "GatewayPorts yes"
    } >> "$SSHD_CONFIG_FILE"

    if ! sshd -t -f "$SSHD_CONFIG_FILE"; then
        cp "$SSHD_CONFIG_BACKUP" "$SSHD_CONFIG_FILE"
        echo "실패! sshd 설정 검증에 실패하여 백업으로 복구했습니다: ${SSHD_CONFIG_BACKUP}"
        exit 1
    fi

    restart_ssh_service
    echo "성공! (sshd 재시작됨)"
fi

# 4. 방화벽 포트 설정 (ufw)
echo "단계 3/3: 방화벽(ufw)에 터널 포트를 허용합니다..."
if ! command -v ufw &> /dev/null; then
    echo "경고: ufw가 설치되어 있지 않습니다. 방화벽 설정을 건너뜁니다."
else
    SSHD_PORTS=$(detect_sshd_ports)
    echo "-> SSH 관리 포트도 함께 허용합니다: ${SSHD_PORTS}"

    for port in $TUNNEL_PORTS_TO_OPEN $SSHD_PORTS; do
        if ! validate_port "$port"; then
            echo "오류: 유효하지 않은 포트 값입니다: ${port}"
            exit 1
        fi

        if ufw status | grep -qw "${port}/tcp"; then
             echo "-> 포트 ${port}/tcp 는 이미 허용되어 있습니다."
        else
             ufw allow "${port}/tcp"
             echo "-> 포트 ${port}/tcp 를 허용했습니다."
        fi
    done
    
    if ufw status | grep -q "Status: active"; then
        echo "-> 방화벽(ufw)은 이미 활성화되어 있습니다."
    else
        echo "y" | ufw enable
        echo "-> 방화벽(ufw)을 활성화했습니다."
    fi
fi

echo "============================================="
echo "✅ Middle Server 설정이 성공적으로 완료되었습니다."
echo "============================================="
