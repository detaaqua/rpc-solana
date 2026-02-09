# rpc-solana

A practical, end-to-end runbook for installing and operating your **own Solana Mainnet-Beta RPC node** (non-voting) on Ubuntu.

> Reality check: running a reliable Solana mainnet RPC is **expensive** (NVMe IOPS, RAM, bandwidth) and requires ongoing ops. Many teams use RPC providers (Helius/Triton/QuickNode) unless they have strong infra needs.

## What you are building

- A **non-voting** Solana validator process configured as an **RPC node**
- JSON-RPC + WebSocket endpoints for your apps
- Systemd-managed service with auto-restart

This guide targets:
- Ubuntu 22.04 LTS
- Mainnet-Beta

## Recommended hardware (Mainnet)

Minimum that tends to work for a serious RPC:
- **CPU:** 16–32 cores
- **RAM:** 128–256 GB
- **Disk:** 2–4 TB **NVMe Gen4** (IOPS matter more than raw size)
- **Network:** 1 Gbps (10 Gbps ideal), high/unmetered traffic

## Ports / Networking

Common ports involved:
- **8899**: JSON-RPC (HTTP)
- **8900**: WebSocket
- **8001+**: gossip/TPU (dynamic range; outbound is important)

If you expose RPC publicly, add:
- firewall rules
- reverse proxy
- rate limiting / allowlists

## 1) OS preparation

```bash
sudo apt update && sudo apt -y upgrade
sudo apt -y install \
  curl wget jq git tmux htop iotop iftop \
  build-essential pkg-config libssl-dev \
  chrony
```

### Time sync (required)

```bash
sudo systemctl enable --now chrony
chronyc tracking
```

## 2) Kernel / limits tuning

### sysctl

```bash
sudo tee /etc/sysctl.d/20-solana.conf >/dev/null <<'EOF'
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

sudo sysctl --system
```

### ulimit

```bash
sudo tee /etc/security/limits.d/90-solana.conf >/dev/null <<'EOF'
* - nofile 1000000
* - nproc  1000000
EOF
```

## 3) Create a dedicated user + data dirs

```bash
sudo useradd -m -s /bin/bash solana
sudo mkdir -p /solana/{ledger,accounts,log,snapshots}
sudo chown -R solana:solana /solana
```

## 4) Install Solana (validator binaries)

Install Solana (pick a version appropriate for mainnet). A simple start:

```bash
sudo -u solana bash -lc 'sh -c "$(curl -sSfL https://release.solana.com/stable/install)"'
```

Verify:

```bash
sudo -u solana bash -lc 'solana --version'
sudo -u solana bash -lc 'solana-validator --version'
```

## 5) Generate identity keypair

```bash
sudo -u solana bash -lc 'mkdir -p ~/.config/solana'
sudo -u solana bash -lc 'solana-keygen new --no-bip39-passphrase -o ~/.config/solana/identity.json'
sudo -u solana bash -lc 'solana-keygen pubkey ~/.config/solana/identity.json'
```

## 6) Create a validator (RPC) startup script

> This is an RPC-oriented config using `--no-voting`. Adjust flags for your needs.

```bash
sudo -u solana bash -lc 'cat > /home/solana/validator.sh <<"EOF"
#!/usr/bin/env bash
set -euo pipefail

IDENTITY=/home/solana/.config/solana/identity.json
LEDGER=/solana/ledger
ACCOUNTS=/solana/accounts
LOG=/solana/log/validator.log

exec solana-validator \
  --identity "$IDENTITY" \
  --ledger "$LEDGER" \
  --accounts "$ACCOUNTS" \
  --log "$LOG" \
  --entrypoint entrypoint.mainnet-beta.solana.com:8001 \
  --entrypoint entrypoint2.mainnet-beta.solana.com:8001 \
  --entrypoint entrypoint3.mainnet-beta.solana.com:8001 \
  --rpc-port 8899 \
  --rpc-bind-address 0.0.0.0 \
  --full-rpc-api \
  --no-voting \
  --dynamic-port-range 8000-8020 \
  --wal-recovery-mode skip_any_corrupted_record \
  --limit-ledger-size \
  --enable-rpc-transaction-history \
  --enable-cpi-and-log-storage \
  --accounts-index program-id spl-token-owner spl-token-mint
EOF
chmod +x /home/solana/validator.sh'
```

### Notes on flags

- `--no-voting`: run as RPC node only
- `--full-rpc-api`: enables full RPC surface
- `--enable-rpc-transaction-history`: heavier disk usage; required for some history queries
- `--enable-cpi-and-log-storage`: stores CPI/log data; heavier disk usage
- `--accounts-index ...`: improves some lookups but increases RAM usage
- `--limit-ledger-size`: helps keep disk from growing unbounded (still large)

## 7) Systemd service

```bash
sudo tee /etc/systemd/system/solana-validator.service >/dev/null <<'EOF'
[Unit]
Description=Solana Validator (RPC Node)
After=network-online.target
Wants=network-online.target

[Service]
User=solana
Group=solana
Type=simple
LimitNOFILE=1000000
ExecStart=/home/solana/validator.sh
Restart=always
RestartSec=5
StandardOutput=append:/solana/log/systemd.out
StandardError=append:/solana/log/systemd.err

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now solana-validator
sudo systemctl status solana-validator --no-pager
```

## 8) Health checks

Logs:

```bash
sudo tail -f /solana/log/validator.log
```

Catchup:

```bash
sudo -u solana bash -lc 'solana catchup --our-localhost 8899'
```

RPC health:

```bash
curl -s http://127.0.0.1:8899 \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}'
```

Slot:

```bash
curl -s http://127.0.0.1:8899 \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"getSlot"}' | jq
```

## 9) Security guidance (important)

If exposing publicly:
- Bind RPC to `127.0.0.1` and expose via Nginx/Caddy
- Add rate limiting / allowlists
- Consider auth tokens
- Monitor abuse (RPC nodes get hammered)

## 10) Operations checklist

- Monitor disk and NVMe health (ledger/accounts growth)
- Monitor RAM and swap (avoid swapping)
- Monitor bandwidth
- Plan upgrades carefully; follow Solana release notes
- Keep snapshots in mind for faster recovery

## Disclaimer

This runbook is a starting point. Solana mainnet requirements and best practices evolve. Always validate flags and versions against current mainnet recommendations.
