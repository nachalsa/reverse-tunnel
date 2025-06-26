#!/bin/bash

# 스크립트가 위치한 디렉토리를 기준으로 설정 파일 경로를 결정
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
CONFIG_FILE="${SCRIPT_DIR}/../config/tunnel.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file not found at $CONFIG_FILE" >&2
    exit 1
fi
# source 명령어는 현재 쉘에 변수를 로드하므로, 별도 export 없이 사용 가능
source "$CONFIG_FILE"

# -R 옵션을 동적으로 생성
SSH_REMOTE_OPTIONS=""
for tunnel in $TUNNELS; do
    SSH_REMOTE_OPTIONS+="-R $tunnel "
done

if [ -z "$SSH_REMOTE_OPTIONS" ]; then
    echo "Error: No tunnels defined in config file." >&2
    exit 1
fi

echo "Starting reverse SSH tunnel to ${MIDDLE_SERVER_TUNNEL_USER}@${MIDDLE_SERVER_HOST_ALIAS}..."
echo "Tunnels: ${TUNNELS}"

# autossh 실행
# -o "StrictHostKeyChecking=accept-new": 처음 접속 시 키를 자동으로 추가. 이후 키 변경 시 경고. (보안 강화)
# -o "ConnectTimeout=10": 연결 시도 시 10초 타임아웃 설정
/usr/bin/autossh -M 0 \
    -o "ServerAliveInterval=30" \
    -o "ServerAliveCountMax=3" \
    -o "ExitOnForwardFailure=yes" \
    -o "ConnectTimeout=10" \
    -o "StrictHostKeyChecking=accept-new" \
    -N ${SSH_REMOTE_OPTIONS} \
    "${MIDDLE_SERVER_TUNNEL_USER}@${MIDDLE_SERVER_HOST_ALIAS}"