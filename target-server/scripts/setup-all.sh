#!/bin/bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "오류: 이 스크립트는 root 권한으로 실행해야 합니다. (sudo ./setup-all.sh)"
    exit 1
fi

if [ -z "${SUDO_USER:-}" ]; then
    echo "오류: root로 직접 로그인하지 마십시오. 일반 사용자 계정에서 'sudo ./setup-all.sh'를 실행하세요."
    exit 1
fi

SERVICE_USER="$SUDO_USER"
PROJECT_ROOT=$(readlink -f "$(dirname "$(readlink -f "$0")")/..")
REPO_ROOT=$(readlink -f "${PROJECT_ROOT}/..")
CONFIG_FILE="${PROJECT_ROOT}/config/setup-all.conf"

run_as_service_user() {
    sudo -u "$SERVICE_USER" "$@"
}

validate_bool() {
    local name="$1"
    local value="$2"
    if [ "$value" != "true" ] && [ "$value" != "false" ]; then
        echo "오류: ${name} 값은 true 또는 false 여야 합니다."
        exit 1
    fi
}

validate_config() {
    if ! [[ "${ADMIN_HOST_ALIAS:-}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "오류: ADMIN_HOST_ALIAS 값이 유효하지 않습니다."
        exit 1
    fi

    if ! [[ "${REMOTE_WORK_DIR:-}" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
        echo "오류: REMOTE_WORK_DIR 값은 안전한 절대 경로여야 합니다."
        exit 1
    fi

    RUN_MIDDLE_PROVISION="${RUN_MIDDLE_PROVISION:-true}"
    RUN_TARGET_SETUP="${RUN_TARGET_SETUP:-true}"
    validate_bool RUN_MIDDLE_PROVISION "$RUN_MIDDLE_PROVISION"
    validate_bool RUN_TARGET_SETUP "$RUN_TARGET_SETUP"
}

copy_middle_files() {
    echo "--- Middle Server 파일 복사: ${ADMIN_HOST_ALIAS}:${REMOTE_WORK_DIR} ---"
    run_as_service_user ssh -o ConnectTimeout=5 "$ADMIN_HOST_ALIAS" "mkdir -p '${REMOTE_WORK_DIR}'"

    if command -v rsync >/dev/null 2>&1; then
        run_as_service_user rsync -az --delete \
            "${REPO_ROOT}/middle-server" \
            "${ADMIN_HOST_ALIAS}:${REMOTE_WORK_DIR}/"
    else
        tar -C "$REPO_ROOT" -cf - middle-server | \
            run_as_service_user ssh "$ADMIN_HOST_ALIAS" "tar -C '${REMOTE_WORK_DIR}' -xf -"
    fi
}

run_middle_provision() {
    copy_middle_files
    echo "--- Middle Server provision 실행 ---"
    run_as_service_user ssh -t "$ADMIN_HOST_ALIAS" \
        "cd '${REMOTE_WORK_DIR}' && sudo ./middle-server/scripts/provision.sh"
}

run_target_setup() {
    echo "--- Target Server setup 실행 ---"
    ADMIN_HOST_ALIAS="$ADMIN_HOST_ALIAS" "${PROJECT_ROOT}/scripts/setup.sh"
}

run_healthcheck() {
    if [ -x /opt/reverse-tunnel/scripts/healthcheck.sh ]; then
        echo "--- healthcheck 실행 ---"
        run_as_service_user /opt/reverse-tunnel/scripts/healthcheck.sh
    fi
}

echo "=== reverse-tunnel 통합 설치 시작 ==="

if [ ! -f "$CONFIG_FILE" ]; then
    echo "오류: 설정 파일(${CONFIG_FILE})이 없습니다."
    echo "해결: target-server/config/setup-all.conf.example 파일을 setup-all.conf 로 복사하고 내용을 수정하세요."
    exit 1
fi

source "$CONFIG_FILE"
validate_config

echo "정보: Middle 관리자 alias=${ADMIN_HOST_ALIAS}"
echo "정보: Middle 작업 디렉토리=${REMOTE_WORK_DIR}"
echo "정보: RUN_MIDDLE_PROVISION=${RUN_MIDDLE_PROVISION}, RUN_TARGET_SETUP=${RUN_TARGET_SETUP}"

if run_as_service_user ssh -o BatchMode=yes -o ConnectTimeout=5 "$ADMIN_HOST_ALIAS" true >/dev/null 2>&1; then
    echo "정보: '${ADMIN_HOST_ALIAS}' 비밀번호 없는 SSH 접속을 확인했습니다."
else
    echo "정보: '${ADMIN_HOST_ALIAS}' 비밀번호 없는 SSH 접속에 실패했습니다. 대화형 SSH 접속을 시도합니다."
    run_as_service_user ssh -o ConnectTimeout=5 "$ADMIN_HOST_ALIAS" true
fi

if [ "$RUN_MIDDLE_PROVISION" = "true" ]; then
    run_middle_provision
fi

if [ "$RUN_TARGET_SETUP" = "true" ]; then
    run_target_setup
fi

run_healthcheck

echo "============================================="
echo "✅ reverse-tunnel 통합 설치가 완료되었습니다."
echo "============================================="
