#!/bin/bash
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
CONFIG_FILE="${SCRIPT_DIR}/../config/tunnel.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file not found at $CONFIG_FILE" >&2
    exit 1
fi
source "$CONFIG_FILE"

USER_HOME=$(getent passwd "$(whoami)" | cut -d: -f6)
USER_SSH_CONFIG="${USER_HOME}/.ssh/config"

if [ ! -f "$USER_SSH_CONFIG" ]; then
    echo "Error: SSH config file not found at $USER_SSH_CONFIG for user $(whoami)" >&2
    exit 1
fi

export AUTOSSH_PATH="/usr/bin/ssh -F ${USER_SSH_CONFIG}"

SSH_REMOTE_OPTIONS=""
for tunnel in $TUNNELS; do
    SSH_REMOTE_OPTIONS+="-R $tunnel "
done

if [ -z "$SSH_REMOTE_OPTIONS" ]; then
    echo "Error: No tunnels defined in config file." >&2
    exit 1
fi

# 최종적으로 실행될 명령어를 로그에 명확하게 남김
COMMAND_TO_RUN="/usr/bin/autossh -M 0 -o \"ServerAliveInterval=30\" -o \"ServerAliveCountMax=3\" -o \"ExitOnForwardFailure=yes\" -o \"ConnectTimeout=10\" -o \"StrictHostKeyChecking=accept-new\" -N ${SSH_REMOTE_OPTIONS} \"${MIDDLE_SERVER_TUNNEL_USER}@${MIDDLE_SERVER_HOST_ALIAS}\""

echo "--- [DEBUG] 최종 실행될 명령어 ---"
echo "${COMMAND_TO_RUN}"
echo "-----------------------------------"

# --- 4. 명령어 실행 ---
echo "--- [INFO] autossh 실행 시도 ---"
eval ${COMMAND_TO_RUN}

# autossh가 실패하면 종료 코드를 기록
AUTOSSH_EXIT_CODE=$?
echo "--- [$(date)] autossh 프로세스 종료. Exit Code: ${AUTOSSH_EXIT_CODE} ---"
exit ${AUTOSSH_EXIT_CODE}

