#!/usr/bin/env bash
set -euo pipefail

# Solana Mainnet-Beta RPC Node installer (non-voting)
# Target: Ubuntu 22.04
# Usage:
#   sudo bash install-solana-rpc.sh
# Notes:
# - This script makes system changes (users, dirs, sysctl, systemd).
# - Review before running in production.

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Please run as root (sudo)." >&2
  exit 1
fi

# ---- Config (edit as needed) ----
SOLANA_USER=${SOLANA_USER:-solana}
DATA_DIR=${DATA_DIR:-/solana}
LEDGER_DIR=${LEDGER_DIR:-$DATA_DIR/ledger}
ACCOUNTS_DIR=${ACCOUNTS_DIR:-$DATA_DIR/accounts}
LOG_DIR=${LOG_DIR:-$DATA_DIR/log}
IDENTITY_PATH=${IDENTITY_PATH:-/home/$SOLANA_USER/.config/solana/identity.json}
RPC_BIND=${RPC_BIND:-0.0.0.0}
RPC_PORT=${RPC_PORT:-8899}
DYNAMIC_PORT_RANGE=${DYNAMIC_PORT_RANGE:-8000-8020}
ENTRYPOINT1=${ENTRYPOINT1:-entrypoint.mainnet-beta.solana.com:8001}
ENTRYPOINT2=${ENTRYPOINT2:-entrypoint2.mainnet-beta.solana.com:8001}
ENTRYPOINT3=${ENTRYPOINT3:-entrypoint3.mainnet-beta.solana.com:8001}
ENABLE_TX_HISTORY=${ENABLE_TX_HISTORY:-true}
ENABLE_CPI_LOG_STORAGE=${ENABLE_CPI_LOG_STORAGE:-true}
LIMIT_LEDGER_SIZE=${LIMIT_LEDGER_SIZE:-true}

# Solana version channel (stable / specific version URL)
SOLANA_INSTALL_URL=${SOLANA_INSTALL_URL:-https://release.solana.com/stable/install}

# ---- Helpers ----
log() { echo "[install] $*"; }

log "Updating packages..."
apt update
apt -y upgrade

log "Installing dependencies..."
apt -y install \
  curl wget jq git tmux htop iotop iftop \
  build-essential pkg-config libssl-dev \
  chrony

log "Enabling time sync (chrony)..."
systemctl enable --now chrony

log "Applying sysctl tuning..."
cat >/etc/sysctl.d/20-solana.conf <<'EOF'
fs.file-max = 1000000
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 134217728
net.core.wmem_default = 134217728
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 4096
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_congestion_control = bbr
vm.max_map_count = 1000000
EOF
sysctl --system

log "Configuring ulimit..."
cat >/etc/security/limits.d/90-solana.conf <<'EOF'
* - nofile 1000000
* - nproc  1000000
EOF

if ! id -u "$SOLANA_USER" >/dev/null 2>&1; then
  log "Creating user: $SOLANA_USER"
  useradd -m -s /bin/bash "$SOLANA_USER"
else
  log "User exists: $SOLANA_USER"
fi

log "Creating data directories under $DATA_DIR"
mkdir -p "$LEDGER_DIR" "$ACCOUNTS_DIR" "$LOG_DIR" "$DATA_DIR/snapshots"
chown -R "$SOLANA_USER":"$SOLANA_USER" "$DATA_DIR"

log "Installing Solana (validator binaries) for user $SOLANA_USER"
# shellcheck disable=SC2016
sudo -u "$SOLANA_USER" bash -lc 'sh -c "$(curl -sSfL '"$SOLANA_INSTALL_URL"')"'

log "Generating identity keypair (if missing)"
if [[ ! -f "$IDENTITY_PATH" ]]; then
  sudo -u "$SOLANA_USER" bash -lc "mkdir -p ~/.config/solana"
  sudo -u "$SOLANA_USER" bash -lc "solana-keygen new --no-bip39-passphrase -o ~/.config/solana/identity.json"
else
  log "Identity already exists: $IDENTITY_PATH"
fi

log "Writing validator startup script"
VALIDATOR_SH="/home/$SOLANA_USER/validator.sh"
cat >"$VALIDATOR_SH" <<EOF
#!/usr/bin/env bash
set -euo pipefail

IDENTITY="$IDENTITY_PATH"
LEDGER="$LEDGER_DIR"
ACCOUNTS="$ACCOUNTS_DIR"
LOG="$LOG_DIR/validator.log"

ARGS=(
  --identity "\$IDENTITY"
  --ledger "\$LEDGER"
  --accounts "\$ACCOUNTS"
  --log "\$LOG"
  --entrypoint "$ENTRYPOINT1"
  --entrypoint "$ENTRYPOINT2"
  --entrypoint "$ENTRYPOINT3"
  --rpc-bind-address "$RPC_BIND"
  --rpc-port "$RPC_PORT"
  --full-rpc-api
  --no-voting
  --dynamic-port-range "$DYNAMIC_PORT_RANGE"
  --wal-recovery-mode skip_any_corrupted_record
  --accounts-index program-id spl-token-owner spl-token-mint
)

if [[ "$LIMIT_LEDGER_SIZE" == "true" ]]; then
  ARGS+=(--limit-ledger-size)
fi
if [[ "$ENABLE_TX_HISTORY" == "true" ]]; then
  ARGS+=(--enable-rpc-transaction-history)
fi
if [[ "$ENABLE_CPI_LOG_STORAGE" == "true" ]]; then
  ARGS+=(--enable-cpi-and-log-storage)
fi

exec solana-validator "\${ARGS[@]}"
EOF
chmod +x "$VALIDATOR_SH"
chown "$SOLANA_USER":"$SOLANA_USER" "$VALIDATOR_SH"

log "Creating systemd service"
cat >/etc/systemd/system/solana-validator.service <<EOF
[Unit]
Description=Solana Validator (RPC Node)
After=network-online.target
Wants=network-online.target

[Service]
User=$SOLANA_USER
Group=$SOLANA_USER
Type=simple
LimitNOFILE=1000000
ExecStart=$VALIDATOR_SH
Restart=always
RestartSec=5
StandardOutput=append:$LOG_DIR/systemd.out
StandardError=append:$LOG_DIR/systemd.err

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now solana-validator

log "Done. Useful commands:"
echo "  sudo systemctl status solana-validator --no-pager"
echo "  sudo tail -f $LOG_DIR/validator.log"
echo "  curl -s http://127.0.0.1:$RPC_PORT -H 'Content-Type: application/json' -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getHealth\"}'"
