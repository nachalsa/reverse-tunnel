#!/bin/bash

# ==============================================================================
# 역방향 SSH 터널 설정 제거 스크립트
# ==============================================================================
# 사용법:
# 1. 이 스크립트를 target-server의 'scripts' 디렉토리에 위치시킵니다.
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
INSTALL_DIR="/opt/reverse-tunnel"
SERVICE_FILE_TARGET="/etc/systemd/system/reverse-tunnel.service"

# --- 메인 로직 ---
echo "=== 역방향 SSH 터널 설정 제거 시작 ==="

# 1. Systemd 서비스 중지 및 비활성화/삭제
echo "단계 1/3: Systemd 서비스를 중지하고 삭제합니다..."
if [ -f "$SERVICE_FILE_TARGET" ]; then
    systemctl stop reverse-tunnel.service || true # 서비스가 이미 멈춰있어도 오류를 내지 않음
    systemctl disable reverse-tunnel.service
    rm -f "$SERVICE_FILE_TARGET"
    systemctl daemon-reload
    systemctl reset-failed
    echo "-> 'reverse-tunnel.service'를 중지, 비활성화하고 파일을 삭제했습니다."
else
    echo "-> 'reverse-tunnel.service' 파일이 없습니다. 건너뜁니다."
fi

# 2. 설치된 파일 삭제
echo "단계 2/3: 설치된 관련 파일(${INSTALL_DIR})을 삭제합니다..."
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    echo "-> '${INSTALL_DIR}' 디렉토리와 모든 하위 파일을 삭제했습니다."
else
    echo "-> '${INSTALL_DIR}' 디렉토리가 없습니다. 건너뜁니다."
fi

# 3. 의존성 패키지 삭제
echo "단계 3/3: 의존성 패키지(autossh)를 삭제합니다..."
# 'dpkg -s'를 사용하여 패키지 설치 여부 확인
if dpkg -s autossh &> /dev/null; then
    apt-get purge -y autossh
    apt-get autoremove -y # 다른 불필요한 의존성도 함께 제거
    echo "-> 'autossh' 패키지를 완전히 삭제했습니다."
else
    echo "-> 'autossh' 패키지가 설치되어 있지 않습니다. 건너뜁니다."
fi

echo "============================================="
echo "✅ Target Server 설정이 성공적으로 제거되었습니다."
echo "============================================="