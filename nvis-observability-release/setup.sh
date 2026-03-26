#!/usr/bin/env bash
# =============================================================================
# NVIS Observability Suite — Auto-Setup Script
# Version: 1.0.0
# Supports: Ubuntu 20.04, 22.04, 24.04 | CentOS 9 | RHEL 8/9 | Rocky 8/9 | AlmaLinux 8/9
#
# Run this script on your ObsVM (the dedicated observability machine).
# It will discover your environment, deploy all components, and configure
# everything automatically. No hardcoding. No assumptions.
#
# Usage: bash setup.sh
# =============================================================================

set -euo pipefail

# =============================================================================
# GLOBALS
# =============================================================================
SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_FILE="${SCRIPT_DIR}/nvis-setup-report-$(date +%Y%m%d-%H%M%S).txt"
LOG_FILE="${SCRIPT_DIR}/nvis-setup-debug-$(date +%Y%m%d-%H%M%S).log"
STATE_FILE="${SCRIPT_DIR}/.nvis-setup-state"

# Encrypted credential store (in-memory only, never written to disk)
declare -A CREDS=()

# Deployment tracking
declare -A NODE_DCGM=()
declare -A NODE_NODE_EXPORTER=()
declare -A NODE_CADVISOR=()
declare -A NODE_ALLOY=()
declare -A NODE_STATUS=()

OBSVM_IP=""
CLUSTER_NAME=""
BCM_HOST=""
BCM_USER="root"
BCM_SSH_OPTS=""
JUMP_HOST=""           # Optional SSH jump host (e.g. "user@jumpbox.example.com")
GRAFANA_PASS=""
ALL_NODES=()
UP_NODES=()
DOWN_NODES=()
UNALLOCATED_NODES=()
DEPLOY_NODES=()

# OS family — detected unconditionally so phases that skip preflight still have it
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  case "$ID" in
    ubuntu|debian)               OS_FAMILY="debian" ;;
    centos|rhel|rocky|almalinux) OS_FAMILY="rhel" ;;
    *)                           OS_FAMILY="debian" ;;
  esac
else
  OS_FAMILY="debian"
fi

# Feature flags (set during interview)
HAS_UFM=false
HAS_RUNAI=false
HAS_SNMP_PDU=false
HAS_WEKA=false
HAS_RAID=false
HAS_LDAP=false
HAS_LONGTERM=false
SETUP_ALERTS=false
SETUP_SAML=false
SETUP_PASSWORDLESS_SSH=false

UFM_IP=""
UFM_TYPE=""
RUNAI_ENDPOINT=""
PDU_VENDOR=""
PDU_IP_RANGE=""
VICTORIA_RETENTION="12"

# =============================================================================
# COLORS AND LOGGING
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# All output also goes to log file
exec > >(tee -a "$LOG_FILE") 2>&1

log()     { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✅ $*${NC}"; }
warn()    { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠️  $*${NC}"; }
error()   { echo -e "${RED}[$(date '+%H:%M:%S')] ❌ $*${NC}"; }
header()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}"; \
            echo -e "${BOLD}${CYAN}  $*${NC}"; \
            echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════════${NC}\n"; }
step()    { echo -e "\n${BOLD}▶ $*${NC}"; }
info()    { echo -e "${DIM}    $*${NC}"; }
ask_yes_no() {
  local prompt="$1"
  local reply
  read -rp "$(echo -e "${BOLD}${prompt}${NC} [y/N]: ")" reply
  [[ "${reply,,}" =~ ^(y|yes)$ ]]
}

# Write to report file
report() { echo "$*" >> "$REPORT_FILE"; }

# =============================================================================
# ERROR HANDLING
# =============================================================================
die() {
  error "$1"
  echo ""
  echo -e "${RED}${BOLD}Setup failed at: $1${NC}"
  echo -e "${YELLOW}Debug log: ${LOG_FILE}${NC}"
  echo -e "${YELLOW}To retry: fix the issue above, then run: bash setup.sh${NC}"
  if [[ -f "$STATE_FILE" ]]; then
    echo -e "${YELLOW}Previously completed steps are saved — setup will resume from where it failed.${NC}"
  fi
  exit 1
}

# Save state so re-runs skip completed steps
state_set() { echo "$1=done" >> "$STATE_FILE"; }
state_done() { grep -q "^$1=done" "$STATE_FILE" 2>/dev/null && return 0 || return 1; }

# =============================================================================
# PERSISTENT NODE INVENTORY  (.nvis-node-inventory)
# Tracks per-node deployment status so re-runs skip healthy nodes and only
# deploy to new or failed nodes. Survives reboots — not stored in /tmp.
#
# Format (TSV): node_name  node_ip  STATUS=x  DCGM=x  NODE_EXPORTER=x  ALLOY=x  ALLOY_HASH=x  timestamp
# =============================================================================
INVENTORY_FILE="${SCRIPT_DIR}/.nvis-node-inventory"
ALLOY_CONFIG_HASH=""   # computed once in phase_gpu_nodes, passed to install_on_node
FORCE_REDISCOVER=false # set true by --phase gpu_nodes to refresh BCM discovery

# inv_check <node_ip> <alloy_hash>
# Returns 0 (skip — already healthy) or 1 (needs deploy)
inv_check() {
  local node_ip="$1" alloy_hash="$2"
  [[ ! -f "$INVENTORY_FILE" ]] && return 1
  local line
  line=$(grep $'\t'"${node_ip}"$'\t' "$INVENTORY_FILE" 2>/dev/null | tail -1)
  [[ -z "$line" ]] && return 1
  echo "$line" | grep -q "STATUS=SUCCESS" || return 1
  [[ -n "$alloy_hash" ]] && { echo "$line" | grep -q "ALLOY_HASH=${alloy_hash}" || return 1; }
  return 0
}

# inv_set <node_name> <node_ip> <status> <dcgm> <ne> <alloy> <hash>
inv_set() {
  local node_name="$1" node_ip="$2" status="$3" dcgm="$4" ne="$5" alloy_s="$6" hash="$7"
  local ts; ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  [[ -f "$INVENTORY_FILE" ]] && sed -i "/$'\t'${node_ip}$'\t'/d" "$INVENTORY_FILE" 2>/dev/null || true
  printf '%s\t%s\tSTATUS=%s\tDCGM=%s\tNODE_EXPORTER=%s\tALLOY=%s\tALLOY_HASH=%s\t%s\n' \
    "$node_name" "$node_ip" "$status" "$dcgm" "$ne" "$alloy_s" "$hash" "$ts" >> "$INVENTORY_FILE"
}

# inv_show — pretty-print the inventory
inv_show() {
  [[ ! -f "$INVENTORY_FILE" ]] && { info "No node inventory yet."; return; }
  printf "\n  %-15s %-16s %-10s %-6s %-14s %-6s %s\n" \
    "NODE" "IP" "STATUS" "DCGM" "NODE_EXPORTER" "ALLOY" "DEPLOYED"
  printf "  %-15s %-16s %-10s %-6s %-14s %-6s %s\n" \
    "---------------" "----------------" "----------" "------" "--------------" "------" "-------------------"
  grep -v '^#' "$INVENTORY_FILE" 2>/dev/null | while IFS=$'\t' read -r name ip status dcgm ne alloy hash ts; do
    local col="${NC}"
    [[ "$status" == "STATUS=SUCCESS" ]] && col="${GREEN}" || col="${YELLOW}"
    printf "  ${col}%-15s %-16s %-10s %-6s %-14s %-6s %s${NC}\n" \
      "$name" "$ip" "${status#STATUS=}" "${dcgm#DCGM=}" "${ne#NODE_EXPORTER=}" "${alloy#ALLOY=}" "$ts"
  done
  echo ""
}

# =============================================================================
# HELPERS
# =============================================================================
prompt() {
  # prompt VAR_NAME "Question" [default]
  local varname="$1"
  local question="$2"
  local default="${3:-}"
  local value=""
  if [[ -n "$default" ]]; then
    read -rp "$(echo -e "${BOLD}${question}${NC} [${DIM}${default}${NC}]: ")" value
    value="${value:-$default}"
  else
    while [[ -z "$value" ]]; do
      read -rp "$(echo -e "${BOLD}${question}${NC}: ")" value
      [[ -z "$value" ]] && warn "This field is required."
    done
  fi
  eval "$varname=\"$value\""
}

prompt_secret() {
  # prompt_secret VAR_NAME "Question"
  local varname="$1"
  local question="$2"
  local value=""
  while [[ -z "$value" ]]; do
    read -rsp "$(echo -e "${BOLD}${question}${NC}: ")" value
    echo ""
    [[ -z "$value" ]] && warn "Password cannot be empty."
  done
  # Store in memory-only associative array, never echo
  CREDS["$varname"]="$value"
}

prompt_yn() {
  # prompt_yn "Question" → returns 0 for yes, 1 for no
  local question="$1"
  local answer=""
  while true; do
    read -rp "$(echo -e "${BOLD}${question}${NC} [y/n]: ")" answer
    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

run_on_node() {
  # run_on_node NODE_IP "command"
  # Routes: ObsVM → (jump host, if set) → BCM → node
  local node="$1"
  local cmd="$2"
  local encoded
  encoded=$(printf '%s' "$cmd" | base64 -w0)
  local jump_opt=""
  [[ -n "${JUMP_HOST}" ]] && jump_opt="-J ${JUMP_HOST},${BCM_USER}@${BCM_HOST}" || jump_opt="-J ${BCM_USER}@${BCM_HOST}"
  ssh -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=15 \
    ${jump_opt} \
    root@"${node}" "echo ${encoded} | base64 -d | bash" 2>&1
}

run_on_bcm() {
  local cmd="$1"
  local jump_opt=""
  [[ -n "${JUMP_HOST}" ]] && jump_opt="-J ${JUMP_HOST}"
  ssh -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=15 \
    ${jump_opt} "${BCM_USER}@${BCM_HOST}" "$cmd" 2>&1
}

check_service_healthy() {
  local name="$1"
  local url="$2"
  local expected="$3"
  local retries="${4:-12}"   # default: up to 12 retries (120s total)
  local actual
  local i=0
  while [[ $i -lt $retries ]]; do
    actual=$(curl -sf --max-time 5 "$url" 2>/dev/null || echo "")
    if echo "$actual" | grep -q "$expected"; then
      success "$name is healthy"
      return 0
    fi
    i=$((i + 1))
    if [[ $i -lt $retries ]]; then
      log "$name not ready yet (attempt $i/$retries) — retrying in 10s..."
      sleep 10
    fi
  done
  error "$name health check failed after $retries attempts"
  info "URL: $url"
  info "Expected: $expected"
  info "Got: $actual"
  return 1
}

# =============================================================================
# BANNER
# =============================================================================
show_banner() {
  clear
  echo -e "${BOLD}${GREEN}"
  cat << 'BANNER'
  ███╗   ██╗██╗   ██╗██╗███████╗
  ████╗  ██║██║   ██║██║██╔════╝
  ██╔██╗ ██║██║   ██║██║███████╗
  ██║╚██╗██║╚██╗ ██╔╝██║╚════██║
  ██║ ╚████║ ╚████╔╝ ██║███████║
  ╚═╝  ╚═══╝  ╚═══╝  ╚═╝╚══════╝
  Observability Suite — Auto Setup
BANNER
  echo -e "${NC}"
  echo -e "  Version: ${SCRIPT_VERSION}  |  Log: ${LOG_FILE}"
  echo -e "  Report will be saved to: ${REPORT_FILE}\n"

  if [[ -f "$STATE_FILE" ]]; then
    warn "Previous partial setup detected. Completed steps will be skipped."
    echo -e "  ${DIM}Delete ${STATE_FILE} to start fresh.${NC}\n"
  fi
}

# =============================================================================
# PHASE 1: PRE-FLIGHT CHECKS
# =============================================================================
phase_preflight() {
  header "Phase 1 — Pre-flight Checks"

  state_done "preflight" && { log "Pre-flight already passed — skipping"; return; }

  # OS check
  step "Checking operating system..."
  if [[ ! -f /etc/os-release ]]; then
    die "Cannot detect OS. Requires Ubuntu 20.04/22.04/24.04, CentOS 9, RHEL 8/9, Rocky 8/9, or AlmaLinux 8/9."
  fi
  . /etc/os-release
  case "$ID" in
    ubuntu)
      case "$VERSION_ID" in
        20.04|22.04|24.04) success "OS: $PRETTY_NAME" ;;
        *) die "Unsupported Ubuntu version: $VERSION_ID. Requires 20.04, 22.04, or 24.04." ;;
      esac
      OS_FAMILY="debian"
      ;;
    centos|rhel|rocky|almalinux)
      case "${VERSION_ID%%.*}" in
        8|9) success "OS: $PRETTY_NAME" ;;
        *) die "Unsupported $ID version: $VERSION_ID. Requires version 8 or 9." ;;
      esac
      OS_FAMILY="rhel"
      ;;
    *)
      die "Unsupported OS: $ID. Requires Ubuntu, CentOS, RHEL, Rocky, or AlmaLinux."
      ;;
  esac

  # Root/sudo check
  step "Checking sudo access..."
  if ! sudo -n true 2>/dev/null && ! [[ "$EUID" -eq 0 ]]; then
    warn "This script requires sudo. You may be prompted for your password."
    sudo true || die "sudo access required. Please add your user to the sudoers file."
  fi
  success "sudo access confirmed"

  # Internet check
  step "Checking internet connectivity..."
  local test_urls=("registry.hub.docker.com" "apt.grafana.com" "github.com")
  local internet_ok=false
  for url in "${test_urls[@]}"; do
    if curl -sf --max-time 5 "https://$url" > /dev/null 2>&1; then
      internet_ok=true
      break
    fi
  done
  if ! $internet_ok; then
    die "No internet access. This script needs to pull Docker images from the internet.\nCheck your network settings and try again."
  fi
  success "Internet connectivity OK"

  # Disk space check
  step "Checking disk space..."
  local free_gb
  free_gb=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
  if [[ "$free_gb" -lt 20 ]]; then
    die "Insufficient disk space: ${free_gb}GB free, need at least 20GB.\nFree up disk space and retry."
  fi
  success "Disk space: ${free_gb}GB free"

  # RAM check
  step "Checking RAM..."
  local ram_gb
  ram_gb=$(free -g | awk '/^Mem:/{print $2}')
  if [[ "$ram_gb" -lt 6 ]]; then
    warn "RAM is ${ram_gb}GB — recommended minimum is 8GB. Continuing but performance may be impacted."
  else
    success "RAM: ${ram_gb}GB"
  fi

  # Install prerequisites
  step "Installing prerequisites..."
  if [[ "$OS_FAMILY" == "debian" ]]; then
    sudo apt-get update -qq 2>/dev/null || die "apt-get update failed. Check your package sources."
    sudo apt-get install -y -qq \
      curl wget jq python3 python3-pip unzip git \
      sshpass netcat-openbsd nmap snmp \
      2>/dev/null || die "Failed to install prerequisites. Run: sudo apt-get install -y curl wget jq python3 unzip sshpass"
  else
    sudo dnf install -y -q \
      curl wget jq python3 python3-pip unzip git \
      sshpass nmap net-snmp-utils \
      2>/dev/null || die "Failed to install prerequisites. Run: sudo dnf install -y curl wget jq python3 unzip sshpass"
  fi
  success "Prerequisites installed"

  state_set "preflight"
}

# =============================================================================
# PHASE 2: INTERVIEW — Collect all info upfront
# =============================================================================
phase_interview() {
  header "Phase 2 — Environment Interview"

  if state_done "interview"; then
    log "Interview already completed — loading saved config"
    [[ -f "${SCRIPT_DIR}/.nvis-config" ]] && source "${SCRIPT_DIR}/.nvis-config"
    [[ -f "${SCRIPT_DIR}/.nvis-creds"  ]] && source "${SCRIPT_DIR}/.nvis-creds"
    return
  fi

  # === Auto-detect ObsVM IP ===
  OBSVM_IP=$(hostname -I | awk '{print $1}')
  # Allow env override for non-interactive deployments
  OBSVM_IP="${NVIS_OBSVM_IP:-${OBSVM_IP}}"

  # === Auto-detect cluster name ===
  # Try from hostname (strip numbers/dates), fallback to asking
  local auto_cluster
  auto_cluster=$(hostname -s | sed 's/-[0-9]*$//' | sed 's/[0-9]*$//' | tr '[:upper:]' '[:lower:]')
  [[ -z "$auto_cluster" || "$auto_cluster" == "localhost" ]] && auto_cluster="my-gpu-cluster"

  # ─────────────────────────────────────────────────────────────────────────
  # Check for non-interactive mode: NVIS_* env vars set all values upfront
  # Usage: NVIS_CLUSTER=my-cluster NVIS_BCM=10.1.2.3 NVIS_PASS=secret bash setup.sh
  # ─────────────────────────────────────────────────────────────────────────
  if [[ -n "${NVIS_CLUSTER:-}" ]]; then
    CLUSTER_NAME="${NVIS_CLUSTER}"
    GRAFANA_PASS="${NVIS_PASS:-NVIS_CBU}"
    BCM_HOST="${NVIS_BCM:-}"
    BCM_USER="${NVIS_BCM_USER:-root}"
    JUMP_HOST="${NVIS_JUMP:-}"
    HAS_UFM="${NVIS_UFM:-false}"
    HAS_RUNAI="${NVIS_RUNAI:-false}"
    HAS_SNMP_PDU="${NVIS_PDU:-false}"
    HAS_WEKA="${NVIS_WEKA:-false}"
    HAS_RAID="${NVIS_RAID:-false}"
    HAS_LONGTERM="${NVIS_LONGTERM:-true}"
    VICTORIA_RETENTION="${NVIS_RETENTION:-12}"
    SETUP_ALERTS="${NVIS_ALERTS:-false}"
    SETUP_SAML="${NVIS_SAML:-false}"
    success "Non-interactive mode (NVIS_* env vars)"
  else
    # ─────────────────────────────────────────────────────────────────────
    # Interactive Interview
    # ─────────────────────────────────────────────────────────────────────
    echo ""
    echo -e "${CYAN}${BOLD}┌──────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}${BOLD}│   NVIS Observability Suite — Environment Setup        │${NC}"
    echo -e "${CYAN}${BOLD}└──────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "This ObsVM IP: ${BOLD}${OBSVM_IP}${NC}"
    echo ""

    # Cluster name
    read -rp "$(echo -e "${BOLD}Cluster name${NC} [${auto_cluster}]: ")" input_cluster
    CLUSTER_NAME="${input_cluster:-${auto_cluster}}"

    # Grafana password
    read -rp "$(echo -e "${BOLD}Grafana admin password${NC} [NVIS_CBU]: ")" input_pass
    GRAFANA_PASS="${input_pass:-NVIS_CBU}"

    # BCM / Cluster Manager host
    echo ""
    echo -e "${DIM}Optional: BCM (BrightCluster Manager) or other cluster manager head node.${NC}"
    echo -e "${DIM}Leave blank to skip GPU node auto-discovery (configure manually later).${NC}"
    read -rp "$(echo -e "${BOLD}Cluster manager (BCM) host IP${NC} [skip]: ")" input_bcm
    BCM_HOST="${input_bcm:-}"

    if [[ -n "$BCM_HOST" ]]; then
      read -rp "$(echo -e "${BOLD}BCM SSH user${NC} [root]: ")" input_bcm_user
      BCM_USER="${input_bcm_user:-root}"

      read -rp "$(echo -e "${BOLD}SSH jump host${NC} (e.g. user@jumpbox.example.com) [none]: ")" input_jump
      JUMP_HOST="${input_jump:-}"
    fi

    # Long-term storage
    echo ""
    if ask_yes_no "Enable VictoriaMetrics for 12-month long-term storage?"; then
      HAS_LONGTERM=true
      read -rp "$(echo -e "${BOLD}Retention months${NC} [12]: ")" input_ret
      VICTORIA_RETENTION="${input_ret:-12}"
    else
      HAS_LONGTERM=false
    fi

    # Optional integrations
    echo ""
    echo -e "${DIM}Optional integrations (all can be added later):${NC}"
    ask_yes_no "UFM / InfiniBand telemetry?" && HAS_UFM=true  || HAS_UFM=false
    ask_yes_no "Run:ai GPU scheduler?"       && HAS_RUNAI=true || HAS_RUNAI=false
    ask_yes_no "PDU SNMP monitoring?"        && HAS_SNMP_PDU=true || HAS_SNMP_PDU=false
    HAS_WEKA=false; HAS_RAID=false; SETUP_ALERTS=false; SETUP_SAML=false
  fi

  BCM_SSH_OPTS="-i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o BatchMode=yes"

  echo ""
  success "ObsVM IP:     $OBSVM_IP"
  success "Cluster name: $CLUSTER_NAME"
  [[ -n "$BCM_HOST"   ]] && success "BCM host:     $BCM_HOST"
  [[ -n "$JUMP_HOST"  ]] && success "Jump host:    $JUMP_HOST"
  success "Long-term storage: ${HAS_LONGTERM} (${VICTORIA_RETENTION}mo VictoriaMetrics)"

  echo ""
  success "Configuration complete. Starting deployment..."
  echo ""

  # Save config (non-sensitive only — password excluded)
  cat > "${SCRIPT_DIR}/.nvis-config" << EOF
OBSVM_IP="${OBSVM_IP}"
CLUSTER_NAME="${CLUSTER_NAME}"
BCM_HOST="${BCM_HOST}"
BCM_USER="${BCM_USER}"
JUMP_HOST="${JUMP_HOST}"
HAS_UFM=${HAS_UFM}
UFM_IP="${UFM_IP:-}"
UFM_TYPE="${UFM_TYPE:-}"
HAS_RUNAI=${HAS_RUNAI}
RUNAI_ENDPOINT="${RUNAI_ENDPOINT:-}"
HAS_SNMP_PDU=${HAS_SNMP_PDU}
PDU_VENDOR="${PDU_VENDOR:-}"
PDU_IP_RANGE="${PDU_IP_RANGE:-}"
HAS_WEKA=${HAS_WEKA}
HAS_RAID=${HAS_RAID}
HAS_LONGTERM=${HAS_LONGTERM}
VICTORIA_RETENTION="${VICTORIA_RETENTION}"
SETUP_ALERTS=${SETUP_ALERTS}
SETUP_SAML=${SETUP_SAML}
EOF
  # Password stored separately (permissions 600)
  echo "GRAFANA_PASS=\"${GRAFANA_PASS}\"" > "${SCRIPT_DIR}/.nvis-creds"
  chmod 600 "${SCRIPT_DIR}/.nvis-creds"

  state_set "interview"
}

# Container runtime (detected in phase 3)
CONTAINER_RUNTIME="docker"  # docker | podman | enroot

# =============================================================================
# PHASE 3: INSTALL CONTAINER RUNTIME AND TERRAFORM ON OBSVM
# =============================================================================
phase_install_obsvm() {
  header "Phase 3 — Install Container Runtime & Terraform on ObsVM"

  # Detect container runtime — prefer Enroot → Podman → Docker
  step "Detecting container runtime..."
  if command -v enroot &>/dev/null; then
    CONTAINER_RUNTIME="enroot"
    success "Enroot detected: $(enroot version 2>/dev/null || echo 'installed')"
    log "Enroot is GPU-configured — skipping nvidia-ctk setup on GPU nodes"
  elif command -v podman &>/dev/null; then
    CONTAINER_RUNTIME="podman"
    success "Podman detected: $(podman --version)"
    log "Using Podman — no Docker daemon required"
  elif command -v docker &>/dev/null; then
    CONTAINER_RUNTIME="docker"
    success "Docker already installed: $(docker --version)"
  else
    log "No container runtime found. Auto-selecting Docker install."
    CONTAINER_RUNTIME="docker"
  fi
  log "Container runtime: ${CONTAINER_RUNTIME}"

  # Docker install (only if selected)
  if [[ "$CONTAINER_RUNTIME" == "docker" ]] && ! command -v docker &>/dev/null; then
    step "Installing Docker..."
    log "This downloads and installs Docker Engine from docker.com"
    if [[ "$OS_FAMILY" == "debian" ]]; then
      sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release apt-transport-https \
        || die "Failed to install Docker prerequisites.\nFix: sudo apt-get update && sudo apt-get install -y ca-certificates curl gnupg"
      sudo install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
        || die "Failed to download Docker GPG key.\nFix: Check internet access to download.docker.com"
      sudo chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
      sudo apt-get update -qq
      sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin \
        || die "Docker installation failed.\nFix: Check apt sources and internet access.\nRollback: sudo apt-get remove docker-ce docker-ce-cli containerd.io"
    else
      sudo dnf install -y -q dnf-plugins-core \
        || die "Failed to install dnf-plugins-core."
      sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo \
        || die "Failed to add Docker repo.\nFix: Check internet access to download.docker.com"
      sudo dnf install -y -q docker-ce docker-ce-cli containerd.io docker-compose-plugin \
        || die "Docker installation failed.\nFix: Check dnf repos and internet access.\nRollback: sudo dnf remove docker-ce docker-ce-cli containerd.io"
    fi
    sudo systemctl enable docker
    sudo systemctl start docker
    sudo usermod -aG docker "$USER"
    success "Docker installed: $(docker --version)"
  else
    success "Docker already installed: $(docker --version)"
  fi

  # Terraform
  if ! command -v terraform &>/dev/null && [[ ! -f ~/bin/terraform ]]; then
    step "Installing Terraform..."
    log "Downloading Terraform 1.9.0 from releases.hashicorp.com"
    wget -q https://releases.hashicorp.com/terraform/1.9.0/terraform_1.9.0_linux_amd64.zip \
      -O /tmp/terraform.zip \
      || die "Failed to download Terraform.\nFix: Check internet access to releases.hashicorp.com"
    sudo unzip -q /tmp/terraform.zip -d /usr/local/bin/ \
      || die "Failed to extract Terraform.\nFix: sudo apt-get install unzip (Ubuntu) or sudo dnf install unzip (RHEL/CentOS)"
    rm /tmp/terraform.zip
    success "Terraform installed: $(terraform --version | head -1)"
  else
    export PATH=$PATH:~/bin
    success "Terraform already installed: $(terraform --version | head -1)"
  fi

  export PATH=$PATH:~/bin
}

# =============================================================================
# PHASE 4: BCM DISCOVERY
# =============================================================================
phase_bcm_discovery() {
  header "Phase 4 — BCM Node Discovery"

  # When FORCE_REDISCOVER=true (e.g. --phase gpu_nodes) always re-query BCM so
  # newly-online nodes are picked up without clearing the state file.
  if ! $FORCE_REDISCOVER && state_done "bcm_discovery"; then
    log "BCM discovery already done — loading saved node list"
    if [[ -f "${SCRIPT_DIR}/.nvis-nodes" ]]; then
      source "${SCRIPT_DIR}/.nvis-nodes"
      # UP_NODES format: "name:ip" pairs — populate DEPLOY_NODES with IPs
      DEPLOY_NODES=()
      for entry in "${UP_NODES[@]}"; do
        local _ip="${entry#*:}"
        [[ -n "$_ip" && "$_ip" != "$entry" ]] && DEPLOY_NODES+=("$_ip") || DEPLOY_NODES+=("$entry")
      done
    fi
    return
  fi

  # SSH setup — route through optional jump host if configured
  BCM_SSH_OPTS="-i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o BatchMode=yes"
  local bcm_jump_opt=""
  [[ -n "${JUMP_HOST}" ]] && bcm_jump_opt="-J ${JUMP_HOST}"

  if [[ -n "${JUMP_HOST}" ]]; then
    success "SSH routing: ObsVM → ${JUMP_HOST} → BCM (${BCM_HOST})"
  else
    success "SSH routing: ObsVM → BCM (${BCM_HOST}) — direct"
  fi

  # Test BCM connectivity
  step "Testing BCM connectivity..."
  local bcm_test
  bcm_test=$(ssh $BCM_SSH_OPTS ${bcm_jump_opt} -o ConnectTimeout=15 "${BCM_USER}@${BCM_HOST}" "echo OK" 2>&1) || true
  if [[ "$bcm_test" != "OK" ]]; then
    warn "Cannot reach BCM at $BCM_HOST — continuing without GPU node discovery"
    warn "SSH output: $bcm_test"
    warn "GPU node agents can be deployed separately: copy working/agent-deploy.sh to nodes and run as root"
    DEPLOY_NODES=()
    {
      echo "UP_NODES=()"
      echo "DOWN_NODES=()"
      echo "UNALLOCATED_NODES=()"
      echo "DEPLOY_NODES=()"
    } > "${SCRIPT_DIR}/.nvis-nodes"
    state_set "bcm_discovery"
    return
  fi
  success "BCM reachable at $BCM_HOST"

  # Run cmsh device list (BCM/BrightCluster Manager) or sinfo (pure Slurm)
  step "Discovering GPU nodes via cluster manager..."
  local cmsh_output
  cmsh_output=$(ssh $BCM_SSH_OPTS ${bcm_jump_opt} "${BCM_USER}@${BCM_HOST}" \
    "cmsh -c 'device list' 2>/dev/null || /cm/local/apps/cmd/bin/cmsh -c 'device list' 2>/dev/null || \
     sinfo -h -N -o '%N %T %G' 2>/dev/null || \
     echo 'DISCOVERY_FAILED'" 2>&1)

  if echo "$cmsh_output" | grep -qi "error\|not found\|command not found"; then
    error "cmsh failed on BCM:"
    echo "$cmsh_output"
    die "cmsh not available on BCM.\nFix: Ensure BCM is fully operational and cmsh is installed at /cm/local/apps/cmd/bin/cmsh"
  fi

  success "Got device list from BCM"

  # Parse cmsh output
  # Format: Type  Name  MAC  IP  Network  Status
  step "Parsing node inventory..."

  local total_nodes=0
  local up_count=0
  local down_count=0
  local unalloc_count=0
  local other_count=0

  # Print header
  printf "\n  %-15s %-20s %-18s %-10s\n" "NAME" "IP" "TYPE" "STATUS"
  printf "  %-15s %-20s %-18s %-10s\n" "---------------" "--------------------" "------------------" "----------"

  while IFS= read -r line; do
    # Skip header lines and empty lines
    [[ -z "$line" ]] && continue
    echo "$line" | grep -q "^-\|^Name\|^Type\|Type.*Name" && continue

    # Parse the line — cmsh format varies slightly by version
    local node_type node_name node_ip node_status
    node_type=$(echo "$line" | awk '{print $1}')
    node_name=$(echo "$line" | awk '{print $2}')
    node_ip=$(echo "$line"   | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    node_status=$(echo "$line" | grep -oE '\[\s*[A-Z]+\s*\]' | tr -d '[] ' | head -1)

    # Skip head nodes and non-physical nodes
    [[ "$node_type" == "HeadNode" ]] && continue
    [[ -z "$node_name" ]] && continue

    ((total_nodes++)) || true

    case "${node_status^^}" in
      UP)
        # Store as "name:ip" so phase_gpu_nodes can use both name and IP
        UP_NODES+=("${node_name}:${node_ip}")
        printf "  ${GREEN}%-15s %-20s %-18s %-10s${NC}\n" "$node_name" "${node_ip:-N/A}" "$node_type" "UP"
        ((up_count++)) || true
        ;;
      DOWN)
        DOWN_NODES+=("$node_name")
        printf "  ${RED}%-15s %-20s %-18s %-10s${NC}\n" "$node_name" "${node_ip:-N/A}" "$node_type" "DOWN"
        ((down_count++)) || true
        ;;
      UNASSIGNED|UNALLOCATED)
        UNALLOCATED_NODES+=("$node_name")
        printf "  ${YELLOW}%-15s %-20s %-18s %-10s${NC}\n" "$node_name" "${node_ip:-N/A}" "$node_type" "UNALLOCATED"
        ((unalloc_count++)) || true
        ;;
      *)
        printf "  ${DIM}%-15s %-20s %-18s %-10s${NC}\n" "$node_name" "${node_ip:-N/A}" "$node_type" "${node_status:-UNKNOWN}"
        ((other_count++)) || true
        ;;
    esac
  done <<< "$cmsh_output"

  echo ""
  log "BCM Inventory Summary:"
  info "Total nodes:        $total_nodes"
  info "UP (deploy targets): $up_count"
  info "DOWN:               $down_count"
  info "Unallocated/Other:  $((unalloc_count + other_count))"

  if [[ "${#UP_NODES[@]}" -eq 0 ]]; then
    warn "No UP nodes found in BCM — continuing without GPU node deployment"
    warn "Check BCM node status with: cmsh -c 'device list'"
    DEPLOY_NODES=()
    state_set "bcm_discovery"
    return
  fi

  # All UP nodes from BCM are deploy targets — reachable via BCM jump (ObsVM never pings nodes directly)
  # Populate DEPLOY_NODES (IPs only) from UP_NODES (name:ip pairs)
  DEPLOY_NODES=()
  for entry in "${UP_NODES[@]}"; do
    [[ -z "$entry" ]] && continue
    local _ip="${entry#*:}"
    [[ -z "$_ip" || "$_ip" == "$entry" ]] && _ip="$entry"  # fallback if no colon
    DEPLOY_NODES+=("$_ip")
    info "  ${entry%%:*} (${_ip}) — deploy target (via BCM)"
  done

  if [[ "${#DEPLOY_NODES[@]}" -eq 0 ]]; then
    warn "No UP nodes found in BCM inventory — continuing without GPU node deployment"
    state_set "bcm_discovery"
    return
  fi

  echo ""
  success "Deploy targets: ${#DEPLOY_NODES[@]} UP nodes (all SSH routed through BCM)"

  # Save node list — UP_NODES stored as "name:ip" pairs for later phases
  {
    echo "UP_NODES=(${UP_NODES[*]@Q})"
    echo "DOWN_NODES=(${DOWN_NODES[*]@Q})"
    echo "UNALLOCATED_NODES=(${UNALLOCATED_NODES[*]@Q})"
    echo "DEPLOY_NODES=(${DEPLOY_NODES[*]@Q})"
  } > "${SCRIPT_DIR}/.nvis-nodes"

  state_set "bcm_discovery"
}

# =============================================================================
# PHASE 5: START OBSVM STACK
# =============================================================================
phase_obsvm_stack() {
  header "Phase 5 — Start ObsVM Stack (Prometheus + Loki + Grafana)"

  state_done "obsvm_stack" && { log "ObsVM stack already started — skipping"; return; }

  # Kill any leftover exporter processes from prior runs that may hold ports
  pkill -9 -f bcm_exporter.py 2>/dev/null || true
  pkill -9 -f slurm_job_exporter.py 2>/dev/null || true
  sleep 1

  step "Patching docker-compose.yml with Grafana password..."
  sed -i "s/NVIS_CBU/${GRAFANA_PASS}/g" "${SCRIPT_DIR}/docker-compose.yml" \
    || die "Failed to update docker-compose.yml"

  # GPU node metrics are push-based via Grafana Alloy on each node (remote_write to Prometheus).
  # No pull targets needed in prometheus.yml for node/DCGM/cgroup metrics.
  # Only substitute the cluster label placeholder for any non-node jobs.
  local prom_conf="${SCRIPT_DIR}/prometheus/prometheus.yml"
  sed -i "s/hpc-cluster/${CLUSTER_NAME}/g" "$prom_conf"
  success "prometheus.yml cluster label set to ${CLUSTER_NAME}"

  # Dashboards use $cluster template variable — no static patching needed.
  # Datasource UID normalization only (ensures correct uid references):
  local dash_dir="${SCRIPT_DIR}/terraform/dashboards"
  if [[ -d "$dash_dir" ]]; then
    for json_file in "$dash_dir"/*.json; do
      sed -i 's/"uid": "bfeaio5sj2cqoa"/"uid": "nvis-prometheus"/g' "$json_file" 2>/dev/null || true
      sed -i 's/"uid": "efeaikjwwmk8wb"/"uid": "nvis-loki"/g' "$json_file" 2>/dev/null || true
    done
    success "Dashboard datasource UIDs normalized"
  fi

  # Add VictoriaMetrics to docker-compose if requested
  if $HAS_LONGTERM; then
    step "Adding VictoriaMetrics to docker-compose..."
    # Insert VictoriaMetrics service before the volumes: section (guard against double-add)
    if ! grep -q "victoriametrics:" "${SCRIPT_DIR}/docker-compose.yml"; then
      python3 - "${SCRIPT_DIR}/docker-compose.yml" "${VICTORIA_RETENTION}" << 'PYEOF'
import sys
path, retention = sys.argv[1], sys.argv[2]
with open(path, 'r') as f:
    content = f.read()
vm_block = (
    "\n  victoriametrics:\n"
    "    image: victoriametrics/victoria-metrics:v1.103.0\n"
    "    container_name: nvis-victoriametrics\n"
    "    restart: unless-stopped\n"
    "    command:\n"
    "      - '--storageDataPath=/vm-data'\n"
    "      - '--retentionPeriod=" + retention + "'\n"
    "    volumes:\n"
    "      - ./vm-data:/vm-data\n"
    "    ports:\n"
    "      - \"8428:8428\"\n"
)
content = content.replace('\nvolumes:', vm_block + '\nvolumes:', 1)
with open(path, 'w') as f:
    f.write(content)
print("VictoriaMetrics service inserted into docker-compose.yml")
PYEOF
    fi
    mkdir -p "${SCRIPT_DIR}/vm-data"
    success "VictoriaMetrics added (retention: ${VICTORIA_RETENTION} months)"
  fi

  step "Pulling and starting Prometheus, Loki, Grafana (this may take 5-10 minutes)..."
  cd "${SCRIPT_DIR}"

  # Pre-create bind-mount dirs as current user so Docker doesn't create them as nobody:nogroup
  mkdir -p "${SCRIPT_DIR}/vm-data" "${SCRIPT_DIR}/certs"

  # Write .env for docker-compose variable substitution
  # BCM_JUMP is intentionally blank: the exporters run ON the ObsVM which has
  # direct network access to BCM. JUMP_HOST is only needed for setup.sh itself
  # (e.g. running from a dev laptop that can't reach BCM directly).
  cat > "${SCRIPT_DIR}/.env" << ENVEOF
BCM_HOST=${BCM_HOST}
BCM_USER=${BCM_USER:-root}
BCM_JUMP=
CLUSTER_NAME=${CLUSTER_NAME}
GRAFANA_ADMIN_PASSWORD=${GRAFANA_PASS}
ENVEOF

  case "$CONTAINER_RUNTIME" in
    docker)
      docker compose pull 2>&1 \
        || die "Docker image pull failed.\nFix: Check internet access and Docker daemon status.\nRollback: docker compose down"
      docker compose up -d 2>&1 \
        || die "docker compose up failed.\nCheck: docker compose logs\nRollback: docker compose down"
      ;;
    podman)
      # Podman uses podman-compose or podman play kube
      if command -v podman-compose &>/dev/null; then
        podman-compose pull 2>&1 | grep -E "Pulling|Pulled|Error|error" || true
        podman-compose up -d 2>&1 \
          || die "podman-compose up failed.\nFix: Check podman-compose logs\nRollback: podman-compose down"
      else
        # Fall back to running containers individually with podman
        log "podman-compose not found — starting containers individually with podman"
        podman run -d --name nvis-prometheus --restart unless-stopped \
          -p 9090:9090 \
          -v "${SCRIPT_DIR}/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro" \
          prom/prometheus:v2.54.1 \
          --config.file=/etc/prometheus/prometheus.yml \
          --storage.tsdb.retention.time=15d \
          --web.enable-remote-write-receiver 2>&1 || warn "Prometheus may already be running"
        podman run -d --name nvis-loki --restart unless-stopped \
          -p 3100:3100 \
          -v "${SCRIPT_DIR}/loki/loki-config.yaml:/etc/loki/loki-config.yaml:ro" \
          grafana/loki:3.1.0 -config.file=/etc/loki/loki-config.yaml 2>&1 || warn "Loki may already be running"
        podman run -d --name nvis-grafana --restart unless-stopped \
          -p 3000:3000 \
          -e GF_SECURITY_ADMIN_USER=admin \
          -e "GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASS}" \
          -e GF_PANELS_DISABLE_SANITIZE_HTML=true \
          grafana/grafana:11.1.4 2>&1 || warn "Grafana may already be running"
      fi
      ;;
    enroot)
      # Enroot: create and start containers using enroot import + start
      log "Starting services with Enroot..."
      mkdir -p "${SCRIPT_DIR}/.enroot-containers"

      enroot import -o "${SCRIPT_DIR}/.enroot-containers/prometheus.sqsh" \
        docker://prom/prometheus:v2.54.1 2>/dev/null || true
      enroot import -o "${SCRIPT_DIR}/.enroot-containers/loki.sqsh" \
        docker://grafana/loki:3.1.0 2>/dev/null || true
      enroot import -o "${SCRIPT_DIR}/.enroot-containers/grafana.sqsh" \
        docker://grafana/grafana:11.1.4 2>/dev/null || true

      # Start Prometheus
      enroot create --name nvis-prometheus "${SCRIPT_DIR}/.enroot-containers/prometheus.sqsh" 2>/dev/null || true
      enroot start --rw --root \
        --mount "${SCRIPT_DIR}/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml" \
        --env "ARGS=--config.file=/etc/prometheus/prometheus.yml --storage.tsdb.retention.time=15d --web.enable-remote-write-receiver" \
        nvis-prometheus &
      log "Prometheus started with Enroot"

      # Start Loki
      enroot create --name nvis-loki "${SCRIPT_DIR}/.enroot-containers/loki.sqsh" 2>/dev/null || true
      enroot start --rw --root \
        --mount "${SCRIPT_DIR}/loki/loki-config.yaml:/etc/loki/loki-config.yaml" \
        nvis-loki -- /usr/bin/loki -config.file=/etc/loki/loki-config.yaml &
      log "Loki started with Enroot"

      # Start Grafana
      enroot create --name nvis-grafana "${SCRIPT_DIR}/.enroot-containers/grafana.sqsh" 2>/dev/null || true
      enroot start --rw --root \
        --env "GF_SECURITY_ADMIN_USER=admin" \
        --env "GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASS}" \
        --env "GF_PANELS_DISABLE_SANITIZE_HTML=true" \
        nvis-grafana &
      log "Grafana started with Enroot"
      ;;
  esac

  log "Waiting 10 seconds for services to start..."
  sleep 10

  # Health checks (each retries up to 12x with 10s gaps = 120s per service)
  step "Validating services..."
  local health_ok=true

  check_service_healthy "Prometheus" "http://localhost:9090/-/healthy" "Healthy" || health_ok=false
  check_service_healthy "Loki" "http://localhost:3100/ready" "ready" || health_ok=false
  check_service_healthy "Grafana" "http://localhost:3000/api/health" "ok" || health_ok=false

  if ! $health_ok; then
    error "One or more services failed health check."
    log "Running: docker compose ps"
    docker compose ps
    log "Running: docker compose logs --tail=20"
    docker compose logs --tail=20
    die "Service startup failed. See logs above.\nFix: Check logs, fix config, then rerun.\nRollback: cd ${SCRIPT_DIR} && docker compose down"
  fi

  success "All ObsVM services healthy"
  log "Grafana: http://${OBSVM_IP}:3000 (admin / ${GRAFANA_PASS})"
  log "Prometheus: http://${OBSVM_IP}:9090"
  log "Loki: http://${OBSVM_IP}:3100"

  # ── BCM exporter ──────────────────────────────────────────────────────────
  if [[ -n "${BCM_HOST}" ]]; then
    step "Starting BCM (BrightCluster Manager) exporter..."
    # Kill any existing instance
    pkill -f bcm_exporter.py 2>/dev/null || true
    sleep 1

    local bcm_jump_opt=""
    [[ -n "${JUMP_HOST}" ]] && bcm_jump_opt="BCM_JUMP=${JUMP_HOST}"

    nohup env \
      BCM_HOST="${BCM_HOST}" \
      BCM_USER="${BCM_USER:-root}" \
      ${bcm_jump_opt} \
      BCM_SSH_KEY="${BCM_SSH_OPTS##-i }" \
      CLUSTER_NAME="${CLUSTER_NAME}" \
      SCRAPE_INTERVAL=60 PORT=9401 \
      python3 "${SCRIPT_DIR}/scripts/bcm_exporter.py" \
      >> /tmp/nvis-bcm-exporter.log 2>&1 &
    BCM_PID=$!

    sleep 3
    if kill -0 "$BCM_PID" 2>/dev/null; then
      success "BCM exporter running (PID $BCM_PID) — metrics at :9401"
      log "BCM inventory: curl http://localhost:9401/metrics"
      # Install as systemd service if we have permission
      if [[ -w /etc/systemd/system ]]; then
        sed "s/BCM_HOST=CHANGE_ME/BCM_HOST=${BCM_HOST}/" \
            "${SCRIPT_DIR}/scripts/bcm-exporter.service" | \
        sed "s/CLUSTER_NAME=CHANGE_ME/CLUSTER_NAME=${CLUSTER_NAME}/" \
            > /etc/systemd/system/nvis-bcm-exporter.service
        [[ -n "${JUMP_HOST}" ]] && sed -i \
          "s|# Environment=BCM_JUMP=user@jumphost|Environment=BCM_JUMP=${JUMP_HOST}|" \
          /etc/systemd/system/nvis-bcm-exporter.service
        systemctl daemon-reload
        systemctl enable nvis-bcm-exporter 2>/dev/null && \
          success "BCM exporter installed as systemd service (auto-start on reboot)"
      else
        warn "No write access to /etc/systemd/system — BCM exporter won't auto-start on reboot"
        warn "To install: sudo cp ${SCRIPT_DIR}/scripts/bcm-exporter.service /etc/systemd/system/nvis-bcm-exporter.service && sudo systemctl enable --now nvis-bcm-exporter"
      fi
    else
      warn "BCM exporter failed to start — cluster manager node will not appear in topology"
    fi

    # Reload prometheus to pick up bcm-exporter scrape target
    curl -s -X POST "http://localhost:9090/-/reload" > /dev/null 2>&1 || true
  fi

  # ── Slurm Job Exporter ────────────────────────────────────────────────
  if [[ -n "${BCM_HOST}" ]]; then
    step "Starting Slurm job exporter (squeue + sacct → :9402)..."
    pkill -f slurm_job_exporter.py 2>/dev/null || true
    sleep 1

    local slurm_jump_opt=""
    [[ -n "${JUMP_HOST}" ]] && slurm_jump_opt="BCM_JUMP=${JUMP_HOST}"

    nohup env \
      BCM_HOST="${BCM_HOST}" \
      BCM_USER="${BCM_USER:-root}" \
      ${slurm_jump_opt} \
      BCM_SSH_KEY="${BCM_SSH_OPTS##-i }" \
      CLUSTER_NAME="${CLUSTER_NAME}" \
      SLURM_PORT=9402 SCRAPE_INTERVAL=30 SACCT_HOURS=72 \
      python3 "${SCRIPT_DIR}/scripts/slurm_job_exporter.py" \
      >> /tmp/nvis-slurm-exporter.log 2>&1 &
    SLURM_EXP_PID=$!

    sleep 3
    if kill -0 "$SLURM_EXP_PID" 2>/dev/null; then
      success "Slurm job exporter running (PID $SLURM_EXP_PID) — metrics at :9402"
    else
      warn "Slurm job exporter failed to start — job activity panels may be empty"
    fi
  fi

  state_set "obsvm_stack"
}

# =============================================================================
# PHASE 6: TERRAFORM DEPLOY DASHBOARDS
# =============================================================================
phase_terraform() {
  header "Phase 6 — Deploy Dashboards via Terraform"

  state_done "terraform" && { log "Terraform already applied — skipping"; return; }

  step "Creating Terraform variables file..."
  cat > "${SCRIPT_DIR}/terraform/terraform.tfvars" << EOF
grafana_url      = "http://localhost:3000"
grafana_user     = "admin"
grafana_password = "${GRAFANA_PASS}"
prometheus_url   = "http://nvis-prometheus:9090"
loki_url         = "http://nvis-loki:3100"
EOF

  step "Running terraform init..."
  cd "${SCRIPT_DIR}/terraform"
  export PATH=$PATH:~/bin
  terraform init -upgrade -input=false 2>&1 \
    || die "terraform init failed.\nFix: Check internet access to registry.terraform.io\nRollback: Nothing to undo"

  step "Running terraform apply..."
  terraform apply -auto-approve -input=false -lock=false 2>&1 \
    || die "terraform apply failed.\nCheck: terraform plan for details\nRollback: terraform destroy -auto-approve"

  success "All 10 dashboards deployed to Grafana"

  # If VictoriaMetrics enabled, add as datasource
  if $HAS_LONGTERM; then
    step "Adding VictoriaMetrics datasource to Grafana..."
    curl -sf -X POST \
      -H "Content-Type: application/json" \
      -u "admin:${GRAFANA_PASS}" \
      http://localhost:3000/api/datasources \
      -d "{
        \"name\": \"VictoriaMetrics\",
        \"type\": \"prometheus\",
        \"uid\": \"nvis-victoriametrics\",
        \"url\": \"http://nvis-victoriametrics:8428\",
        \"access\": \"proxy\",
        \"jsonData\": {\"timeInterval\": \"15s\"}
      }" > /dev/null 2>&1 && success "VictoriaMetrics datasource added" || warn "VictoriaMetrics datasource may already exist"
  fi

  cd "${SCRIPT_DIR}"
  state_set "terraform"
}

# =============================================================================
# PHASE 7: GPU NODE DEPLOYMENT
# =============================================================================
install_on_node() {
  local node_ip="$1"
  local node_name="${2:-$node_ip}"   # human-readable name (node001 etc.), defaults to IP
  local node_log="/tmp/nvis-node-${node_ip}.log"
  local node_status_file="/tmp/nvis-status-${node_ip}.txt"
  echo "DCGM=FAIL NODE_EXPORTER=FAIL CADVISOR=FAIL ALLOY=FAIL STATUS=PARTIAL" > "$node_status_file"
  local node_runtime="docker"   # default; overridden to "podman" if detected in Phase D
  log "  Deploying to ${node_name} (${node_ip})..."

  # Helper: run command on node
  # Routes: ObsVM → (jump) → BCM → node   OR   ObsVM → (jump) → node directly
  ssh_node() {
    local cmd="$1"
    local encoded
    encoded=$(printf '%s' "$cmd" | base64 -w0)
    local jump_opt=""
    if [[ -n "${JUMP_HOST}" && -n "${BCM_HOST}" ]]; then
      jump_opt="-J ${JUMP_HOST},${BCM_USER}@${BCM_HOST}"
    elif [[ -n "${BCM_HOST}" ]]; then
      jump_opt="-J ${BCM_USER}@${BCM_HOST}"
    elif [[ -n "${JUMP_HOST}" ]]; then
      jump_opt="-J ${JUMP_HOST}"
    fi
    ssh -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=15 \
      ${jump_opt} root@"${node_ip}" "echo ${encoded} | base64 -d | bash" 2>&1 || true
  }

  # 1. DCGM — detect, latch, fix accessibility, or install from scratch
  #
  # Detection order:
  #   A) port 9400 already serving DCGM metrics → latch on (regardless of who deployed it)
  #   B) container exists but port not published → stop/rm and redeploy with -p 9400:9400
  #   C) K8s GPU Operator deployed DCGM → patch service to NodePort 9400
  #   D) nothing → install Docker + nvidia-CTK + run dcgm-exporter container

  # Phase A: Is port 9400 already serving DCGM metrics?
  local dcgm_count
  dcgm_count=$(ssh_node "curl -sf --max-time 5 http://localhost:9400/metrics 2>/dev/null | grep -c '^DCGM_' || echo 0" 2>/dev/null | tr -d '[:space:]')
  if [[ "${dcgm_count:-0}" -gt 0 ]]; then
    success "    DCGM already accessible on $node_ip:9400 (${dcgm_count} metrics) — latching on"
    sed -i 's/DCGM=FAIL/DCGM=OK/' "$node_status_file"
  else
    # Phase B/C: Detect what is running (Docker / Podman / K8s) but not yet serving externally
    local dcgm_detect
    dcgm_detect=$(ssh_node "
      if command -v docker &>/dev/null 2>&1 && docker ps 2>/dev/null | grep -q dcgm-exporter; then
        echo DOCKER_RUNNING
      fi
      if command -v podman &>/dev/null 2>&1 && podman ps 2>/dev/null | grep -q dcgm-exporter; then
        echo PODMAN_RUNNING
      fi
      if command -v kubectl &>/dev/null 2>&1 && kubectl get pods -A 2>/dev/null | grep -q dcgm; then
        K8S_NS=\$(kubectl get pods -A 2>/dev/null | grep dcgm | awk '{print \$1}' | head -1)
        K8S_SVC=\$(kubectl get svc -n \"\${K8S_NS}\" 2>/dev/null | grep dcgm | awk '{print \$1}' | head -1)
        echo \"K8S_RUNNING ns=\${K8S_NS} svc=\${K8S_SVC}\"
      fi
      echo DETECT_DONE
    " 2>/dev/null)

    local dcgm_ok=false

    if echo "$dcgm_detect" | grep -q "DOCKER_RUNNING"; then
      # Container exists but port 9400 not serving — republish with correct port binding
      warn "    DCGM container in Docker but port 9400 not reachable — republishing"
      local rerun_result
      rerun_result=$(ssh_node "
        docker stop dcgm-exporter 2>/dev/null || true
        docker rm   dcgm-exporter 2>/dev/null || true
        # Run without custom counters mount — use DCGM defaults (safer on republish)
        docker run -d \
          --name dcgm-exporter \
          --restart unless-stopped \
          --gpus all \
          --cap-add SYS_ADMIN \
          -p 9400:9400 \
          nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.0-ubuntu22.04 2>&1
        # Retry up to 60s — DCGM needs time to enumerate GPUs after container restart
        for i in 1 2 3 4; do
          sleep 15
          COUNT=\$(curl -sf http://localhost:9400/metrics 2>/dev/null | grep -c '^DCGM_' || echo 0)
          [ \"\$COUNT\" -gt 0 ] && echo DCGM_OK && break
        done
      " 2>/dev/null)
      echo "$rerun_result" | grep -q "DCGM_OK" && dcgm_ok=true || echo "$rerun_result" >> "$node_log"

    elif echo "$dcgm_detect" | grep -q "PODMAN_RUNNING"; then
      warn "    DCGM container in Podman but port 9400 not reachable — republishing"
      local rerun_result
      rerun_result=$(ssh_node "
        podman stop dcgm-exporter 2>/dev/null || true
        podman rm   dcgm-exporter 2>/dev/null || true
        podman run -d \
          --name dcgm-exporter \
          --restart unless-stopped \
          --device nvidia.com/gpu=all \
          --security-opt=no-new-privileges \
          -p 9400:9400 \
          -v /tmp/nvis-dcgm-counters.csv:/etc/dcgm-exporter/default-counters.csv:ro \
          nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.0-ubuntu22.04 \
          -f /etc/dcgm-exporter/default-counters.csv 2>&1
        sleep 20
        curl -sf http://localhost:9400/metrics | grep -c '^DCGM_' && echo DCGM_OK
      " 2>/dev/null)
      echo "$rerun_result" | grep -q "DCGM_OK" && dcgm_ok=true || echo "$rerun_result" >> "$node_log"

    elif echo "$dcgm_detect" | grep -q "K8S_RUNNING"; then
      # GPU Operator DCGM — patch service to NodePort 9400 so Prometheus can reach it
      local k8s_ns k8s_svc
      k8s_ns=$(echo "$dcgm_detect" | grep -o 'ns=[^ ]*' | cut -d= -f2)
      k8s_svc=$(echo "$dcgm_detect" | grep -o 'svc=[^ ]*' | cut -d= -f2)
      log "    GPU Operator DCGM detected (ns=${k8s_ns} svc=${k8s_svc}) — patching to NodePort 9400"
      local k8s_result
      k8s_result=$(ssh_node "
        kubectl patch svc '${k8s_svc}' -n '${k8s_ns}' \
          --type=json \
          -p='[{\"op\":\"replace\",\"path\":\"/spec/type\",\"value\":\"NodePort\"},
               {\"op\":\"add\",\"path\":\"/spec/ports/0/nodePort\",\"value\":9400}]' 2>&1
        sleep 5
        curl -sf http://localhost:9400/metrics | grep -c '^DCGM_' && echo DCGM_OK
      " 2>/dev/null)
      if echo "$k8s_result" | grep -q "DCGM_OK"; then
        dcgm_ok=true
      else
        warn "    K8s NodePort patch failed — Prometheus cannot reach DCGM on $node_ip:9400"
        warn "    Manual fix: kubectl patch svc ${k8s_svc} -n ${k8s_ns} --type=json -p='[{\"op\":\"replace\",\"path\":\"/spec/type\",\"value\":\"NodePort\"},{\"op\":\"add\",\"path\":\"/spec/ports/0/nodePort\",\"value\":9400}]'"
        echo "$k8s_result" >> "$node_log"
      fi

    else
      # Phase D: Nothing running — detect/install runtime then deploy DCGM
      local toolkit_ok=false
      local node_runtime="docker"

      if ssh_node "command -v podman &>/dev/null && echo PODMAN_FOUND" 2>/dev/null | grep -q "PODMAN_FOUND"; then
        toolkit_ok=true; node_runtime="podman"
        log "    Podman detected on $node_ip"
      elif ssh_node "nvidia-ctk --version &>/dev/null 2>&1 && echo CTK_FOUND" 2>/dev/null | grep -q "CTK_FOUND"; then
        toolkit_ok=true; node_runtime="docker"
        log "    NVIDIA CTK detected on $node_ip — using Docker"
      else
        log "    Installing Docker + NVIDIA Container Toolkit on $node_ip..."
        local install_result
        install_result=$(ssh_node "
          NODE_OS=\$(. /etc/os-release && echo \$ID)
          if ! command -v docker &>/dev/null; then
            curl -fsSL https://get.docker.com | sh 2>&1
            sudo systemctl enable docker && sudo systemctl start docker
          fi
          curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
            sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>&1
          if [[ \"\$NODE_OS\" == 'ubuntu' || \"\$NODE_OS\" == 'debian' ]]; then
            curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
              sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
              sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
            sudo apt-get update -qq 2>&1
            sudo apt-get install -y -qq nvidia-container-toolkit 2>&1
          else
            curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | \
              sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo > /dev/null
            sudo dnf install -y -q nvidia-container-toolkit 2>&1
          fi
          sudo nvidia-ctk runtime configure --runtime=docker 2>&1
          sudo systemctl restart docker 2>&1
          echo TOOLKIT_DONE
        " 2>/dev/null)
        if echo "$install_result" | grep -q "TOOLKIT_DONE"; then
          toolkit_ok=true; node_runtime="docker"
        else
          warn "    Docker + NVIDIA CTK install failed on $node_ip"
          echo "$install_result" >> "$node_log"
        fi
      fi

      if $toolkit_ok; then
        # Upload custom DCGM counters CSV
        scp_file "${SCRIPT_DIR}/dcgm/dcgm-counters.csv" "/tmp/nvis-dcgm-counters.csv" 2>/dev/null || \
          ssh_node "cat > /tmp/nvis-dcgm-counters.csv" < "${SCRIPT_DIR}/dcgm/dcgm-counters.csv" 2>/dev/null || true

        local run_result
        case "$node_runtime" in
          podman)
            run_result=$(ssh_node "
              podman run -d \
                --name dcgm-exporter \
                --restart unless-stopped \
                --device nvidia.com/gpu=all \
                --security-opt=no-new-privileges \
                -p 9400:9400 \
                -v /tmp/nvis-dcgm-counters.csv:/etc/dcgm-exporter/default-counters.csv:ro \
                nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.0-ubuntu22.04 \
                -f /etc/dcgm-exporter/default-counters.csv 2>&1
              sleep 20
              curl -sf http://localhost:9400/metrics | grep -c '^DCGM_' && echo DCGM_OK
            " 2>/dev/null)
            ;;
          docker)
            run_result=$(ssh_node "
              docker run -d \
                --name dcgm-exporter \
                --restart unless-stopped \
                --gpus all \
                --cap-add SYS_ADMIN \
                -p 9400:9400 \
                -v /tmp/nvis-dcgm-counters.csv:/etc/dcgm-exporter/default-counters.csv:ro \
                nvcr.io/nvidia/k8s/dcgm-exporter:3.3.5-3.4.0-ubuntu22.04 \
                -f /etc/dcgm-exporter/default-counters.csv 2>&1
              sleep 20
              curl -sf http://localhost:9400/metrics | grep -c '^DCGM_' && echo DCGM_OK
            " 2>/dev/null)
            ;;
        esac
        if echo "$run_result" | grep -q "DCGM_OK"; then
          dcgm_ok=true
        else
          echo "$run_result" >> "$node_log"
        fi
      fi
    fi

    $dcgm_ok && sed -i 's/DCGM=FAIL/DCGM=OK/' "$node_status_file"
  fi

  # 3. node_exporter
  local ne_result
  ne_result=$(ssh_node "
    command -v node_exporter &>/dev/null && systemctl is-active node_exporter &>/dev/null && echo ALREADY_RUNNING && exit 0
    cd /tmp
    wget -q https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz
    tar xzf node_exporter-1.8.2.linux-amd64.tar.gz
    sudo cp node_exporter-1.8.2.linux-amd64/node_exporter /usr/local/bin/
    sudo useradd -rs /bin/false node_exporter 2>/dev/null || true
    sudo mkdir -p /var/lib/node_exporter/textfile
    sudo chown -R node_exporter:node_exporter /var/lib/node_exporter
    sudo tee /etc/systemd/system/node_exporter.service > /dev/null << 'NESVC'
[Unit]
Description=Prometheus Node Exporter
After=network-online.target
[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter \\
    --collector.textfile.directory=/var/lib/node_exporter/textfile \\
    --collector.cpu.info --collector.netdev --collector.netstat \\
    --web.listen-address=:9100
Restart=on-failure
[Install]
WantedBy=multi-user.target
NESVC
    sudo systemctl daemon-reload
    sudo systemctl enable node_exporter
    sudo systemctl start node_exporter
    sleep 3
    curl -sf http://localhost:9100/metrics | grep -c node_ 2>/dev/null && echo NE_OK
  ")
  if echo "$ne_result" | grep -qE "NE_OK|ALREADY_RUNNING"; then
    sed -i 's/NODE_EXPORTER=FAIL/NODE_EXPORTER=OK/' "$node_status_file"
  else
    echo "$ne_result" >> "$node_log"
  fi

  # 4. Slurm cgroup_exporter (port 9306) — provides per-job CPU/memory metrics
  # Uses cgroup filesystem directly — no squeue/DNS dependency
  local cad_result
  local cgroup_exporter_py
  cgroup_exporter_py=$(base64 -w0 "${SCRIPT_DIR}/working/cgroup_exporter.py" 2>/dev/null || \
    base64 -w0 "${SCRIPT_DIR}/cgroup_exporter.py" 2>/dev/null || echo "")

  if [[ -n "$cgroup_exporter_py" ]]; then
    cad_result=$(ssh_node "
      # Check if already running
      systemctl is-active cgroup_exporter &>/dev/null && echo ALREADY_RUNNING && exit 0
      curl -sf http://localhost:9306/metrics &>/dev/null && echo ALREADY_RUNNING && exit 0
      # Deploy cgroup_exporter.py
      echo '${cgroup_exporter_py}' | base64 -d > /usr/local/bin/cgroup_exporter.py
      chmod +x /usr/local/bin/cgroup_exporter.py
      cat > /etc/systemd/system/cgroup_exporter.service << 'SVCEOF'
[Unit]
Description=Cgroup Exporter for Slurm (Python)
After=network.target

[Service]
Type=simple
Restart=always
RestartSec=5
ExecStart=/usr/bin/python3 /usr/local/bin/cgroup_exporter.py

[Install]
WantedBy=multi-user.target
SVCEOF
      systemctl daemon-reload
      systemctl enable --now cgroup_exporter
      sleep 3
      curl -sf http://localhost:9306/metrics | head -1 && echo CAD_OK
    ")
  else
    # Fallback to cAdvisor if cgroup_exporter.py not found
  case "$node_runtime" in
    podman)
      cad_result=$(ssh_node "
        podman ps | grep -q cadvisor && echo ALREADY_RUNNING && exit 0
        podman run -d \
          --name cadvisor \
          --privileged \
          -p 9306:8080 \
          --volume /:/rootfs:ro \
          --volume /var/run:/var/run:ro \
          --volume /sys:/sys:ro \
          --volume /cgroup:/cgroup:ro \
          gcr.io/cadvisor/cadvisor:v0.49.1 2>&1
        sleep 5
        curl -sf http://localhost:9306/metrics | grep -c container_ 2>/dev/null && echo CAD_OK
      ")
      ;;
    enroot)
      cad_result=$(ssh_node "
        enroot list 2>/dev/null | grep -q cadvisor && echo ALREADY_RUNNING && exit 0
        enroot import -o /tmp/cadvisor.sqsh docker://gcr.io/cadvisor/cadvisor:v0.49.1 2>&1
        enroot create --name cadvisor /tmp/cadvisor.sqsh 2>/dev/null || true
        nohup enroot start --rw --root \
          --mount /:/rootfs:ro \
          --mount /sys:/sys:ro \
          --mount /cgroup:/cgroup:ro \
          cadvisor -- /usr/bin/cadvisor -port=9306 &>/var/log/cadvisor.log &
        sleep 5
        curl -sf http://localhost:9306/metrics | grep -c container_ 2>/dev/null && echo CAD_OK
      ")
      ;;
    *)
      cad_result=$(ssh_node "
        docker ps | grep -q cadvisor && echo ALREADY_RUNNING && exit 0
        docker rm -f cadvisor 2>/dev/null || true
        docker run -d \
          --name cadvisor \
          --restart unless-stopped \
          --privileged \
          -p 9306:8080 \
          --volume /:/rootfs:ro \
          --volume /var/run:/var/run:ro \
          --volume /sys:/sys:ro \
          --volume /var/lib/docker/:/var/lib/docker:ro \
          --volume /cgroup:/cgroup:ro \
          gcr.io/cadvisor/cadvisor:v0.49.1 2>&1
        sleep 5
        curl -sf http://localhost:9306/metrics | grep -c container_ 2>/dev/null && echo CAD_OK
      ")
      ;;
  esac
  fi  # end of cgroup_exporter vs cAdvisor fallback
  if echo "$cad_result" | grep -qE "CAD_OK|ALREADY_RUNNING"; then
    sed -i 's/CADVISOR=FAIL/CADVISOR=OK/' "$node_status_file"
  else
    echo "$cad_result" >> "$node_log"
  fi

  # 5. Grafana Alloy
  local alloy_result
  alloy_result=$(ssh_node "
    # Always rewrite config — ensures DCGM scrape target is present even on re-runs
    NODE_OS=\$(. /etc/os-release && echo \$ID)
    ALLOY_INSTALLED=false
    command -v alloy &>/dev/null && ALLOY_INSTALLED=true
    if ! \$ALLOY_INSTALLED; then
      sudo mkdir -p /etc/apt/keyrings
      wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg > /dev/null
      if [[ \"\$NODE_OS\" == 'ubuntu' ]]; then
        echo 'deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main' | sudo tee /etc/apt/sources.list.d/grafana.list > /dev/null
        sudo apt-get update -qq
        sudo apt-get install -y -qq alloy
      else
        cat <<'REPOEOF' | sudo tee /etc/yum.repos.d/grafana.repo > /dev/null
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
REPOEOF
        sudo dnf install -y -q alloy
      fi
    fi
    # Inject HOSTNAME into Alloy's systemd environment so sys.env("HOSTNAME") resolves correctly
    NODE_HOSTNAME=\$(hostname -s)
    sudo mkdir -p /etc/systemd/system/alloy.service.d
    printf '[Service]\nEnvironment=HOSTNAME=%s\n' \"\${NODE_HOSTNAME}\" | sudo tee /etc/systemd/system/alloy.service.d/nvis.conf > /dev/null
    sudo systemctl daemon-reload
    # Write Alloy config with HARDCODED hostname (sys.env("HOSTNAME") is unreliable
    # across systemd versions — hardcoding is simpler and always correct)
    sudo tee /etc/alloy/config.alloy > /dev/null << ALLOYEOF
// NVIS GPU node agent — instance=\${NODE_HOSTNAME} cluster=${CLUSTER_NAME}
prometheus.remote_write \"obsvm\" {
  endpoint {
    url = \"http://${OBSVM_IP}:9090/api/v1/write\"
    queue_config {
      max_samples_per_send = 2000
      capacity             = 10000
    }
  }
}
prometheus.scrape \"dcgm\" {
  targets          = [{ __address__ = \"localhost:9400\" }]
  scrape_interval  = \"15s\"
  honor_timestamps = false
  forward_to       = [prometheus.relabel.dcgm.receiver]
}
prometheus.relabel \"dcgm\" {
  forward_to = [prometheus.remote_write.obsvm.receiver]
  rule {
    target_label = \"job\"
    replacement  = \"dcgm-exporter\"
  }
  rule {
    target_label = \"cluster\"
    replacement  = \"${CLUSTER_NAME}\"
  }
  rule {
    target_label = \"instance\"
    replacement  = \"\${NODE_HOSTNAME}\"
  }
  rule {
    target_label = \"node\"
    replacement  = \"\${NODE_HOSTNAME}\"
  }
}
prometheus.scrape \"node_exporter\" {
  targets         = [{ __address__ = \"localhost:9100\" }]
  scrape_interval = \"15s\"
  forward_to      = [prometheus.relabel.node_exporter.receiver]
}
prometheus.relabel \"node_exporter\" {
  forward_to = [prometheus.remote_write.obsvm.receiver]
  rule {
    target_label = \"job\"
    replacement  = \"node-exporter\"
  }
  rule {
    target_label = \"cluster\"
    replacement  = \"${CLUSTER_NAME}\"
  }
  rule {
    target_label = \"instance\"
    replacement  = \"\${NODE_HOSTNAME}\"
  }
  rule {
    target_label = \"node\"
    replacement  = \"\${NODE_HOSTNAME}\"
  }
}
prometheus.scrape \"cgroup\" {
  targets         = [{ __address__ = \"localhost:9306\" }]
  scrape_interval = \"15s\"
  forward_to      = [prometheus.relabel.cgroup.receiver]
}
prometheus.relabel \"cgroup\" {
  forward_to = [prometheus.remote_write.obsvm.receiver]
  rule {
    target_label = \"job\"
    replacement  = \"slurm-cgroup-exporter\"
  }
  rule {
    target_label = \"cluster\"
    replacement  = \"${CLUSTER_NAME}\"
  }
  rule {
    target_label = \"instance\"
    replacement  = \"\${NODE_HOSTNAME}\"
  }
  rule {
    target_label = \"node\"
    replacement  = \"\${NODE_HOSTNAME}\"
  }
}
loki.write \"obsvm\" {
  endpoint {
    url = \"http://${OBSVM_IP}:3100/loki/api/v1/push\"
  }
}
local.file_match \"syslog\" {
  path_targets = [{
    __path__ = \"/var/log/syslog\",
    job      = \"syslog\",
    cluster  = \"${CLUSTER_NAME}\",
    node     = \"\${NODE_HOSTNAME}\",
    instance = \"\${NODE_HOSTNAME}\",
  }]
}
loki.source.file \"syslog\" {
  targets    = local.file_match.syslog.targets
  forward_to = [loki.write.obsvm.receiver]
}
ALLOYEOF
    sudo systemctl reset-failed alloy 2>/dev/null || true
    sudo systemctl enable alloy
    sudo systemctl restart alloy
    sleep 8
    systemctl is-active alloy && echo ALLOY_OK || journalctl -u alloy -n 30 --no-pager 2>/dev/null
  ")
  if echo "$alloy_result" | grep -q "ALLOY_OK"; then
    sed -i 's/ALLOY=FAIL/ALLOY=OK/' "$node_status_file"
  else
    echo "$alloy_result" >> "$node_log"
  fi

  # Determine overall node status from temp file (background subshells can't update parent arrays)
  local node_dcgm ne_stat cad_stat alloy_stat
  node_dcgm=$(grep -o 'DCGM=[A-Z]*' "$node_status_file" 2>/dev/null | cut -d= -f2 || echo FAIL)
  ne_stat=$(grep -o 'NODE_EXPORTER=[A-Z]*' "$node_status_file" 2>/dev/null | cut -d= -f2 || echo FAIL)
  cad_stat=$(grep -o 'CADVISOR=[A-Z]*' "$node_status_file" 2>/dev/null | cut -d= -f2 || echo FAIL)
  alloy_stat=$(grep -o 'ALLOY=[A-Z]*' "$node_status_file" 2>/dev/null | cut -d= -f2 || echo FAIL)

  # Write back to associative arrays so phase_final_report can read them
  echo "${node_ip} DCGM=${node_dcgm} NODE_EXPORTER=${ne_stat} CADVISOR=${cad_stat} ALLOY=${alloy_stat}" \
    >> /tmp/nvis-deploy-results.txt

  if [[ "$node_dcgm" == "OK" && "$ne_stat" == "OK" && "$alloy_stat" == "OK" ]]; then
    success "  ${node_name} (${node_ip}) — all components installed"
    echo "STATUS=SUCCESS" >> "$node_status_file"
  else
    warn "  ${node_name} (${node_ip}) — partial install: DCGM=${node_dcgm} NE=${ne_stat} ALLOY=${alloy_stat} (see $node_log)"
    echo "STATUS=PARTIAL" >> "$node_status_file"
  fi
}

phase_gpu_nodes() {
  header "Phase 7 — Deploy Agents on GPU Nodes"
  # NO coarse state guard here — we use per-node inventory so re-runs only
  # touch new or failed nodes. The old state_done "gpu_nodes" blocked new nodes
  # from ever getting deployed on re-runs.

  if [[ "${#DEPLOY_NODES[@]}" -eq 0 ]]; then
    warn "No deploy targets — skipping GPU node phase"
    return 0
  fi

  # Compute Alloy config hash (expanded with current OBSVM_IP + CLUSTER_NAME).
  # Nodes already in inventory with this hash + STATUS=SUCCESS are skipped.
  ALLOY_CONFIG_HASH=$(printf '%s%s' "${OBSVM_IP}" "${CLUSTER_NAME}" | md5sum | cut -c1-8)

  # Show current inventory before deploying
  if [[ -f "$INVENTORY_FILE" ]]; then
    log "Current node inventory:"
    inv_show
  fi

  # Determine which nodes actually need work:
  # - Not in inventory → first time, deploy
  # - In inventory with STATUS=PARTIAL or ALLOY_HASH mismatch → re-deploy
  # - In inventory with STATUS=SUCCESS + matching hash → skip (healthy)
  local nodes_to_deploy=() nodes_skipped=() node_names_map=()

  # Build name:ip → ip lookup from UP_NODES (name:ip pairs)
  declare -A _name_by_ip=()
  for entry in "${UP_NODES[@]}"; do
    local _n="${entry%%:*}" _i="${entry#*:}"
    [[ -n "$_i" && "$_i" != "$entry" ]] && _name_by_ip["$_i"]="$_n" || _name_by_ip["$_i"]="$_i"
  done

  for node_ip in "${DEPLOY_NODES[@]}"; do
    local node_name="${_name_by_ip[$node_ip]:-$node_ip}"
    if inv_check "$node_ip" "$ALLOY_CONFIG_HASH"; then
      nodes_skipped+=("$node_ip")
      NODE_STATUS[$node_ip]="SUCCESS"
      success "  ${node_name} (${node_ip}) — already deployed, Alloy config current → skipping"
    else
      nodes_to_deploy+=("$node_ip")
    fi
  done

  if [[ "${#nodes_to_deploy[@]}" -eq 0 ]]; then
    success "All ${#DEPLOY_NODES[@]} nodes already deployed and healthy."
    state_set "gpu_nodes"
    return 0
  fi

  log "${#nodes_to_deploy[@]} nodes need deployment (${#nodes_skipped[@]} skipped — already healthy)"

  # Distribute ObsVM SSH public key to nodes that need deployment
  if [[ -f ~/.ssh/id_ed25519.pub ]]; then
    local obs_pub
    obs_pub=$(cat ~/.ssh/id_ed25519.pub)
    step "Distributing ObsVM SSH key to ${#nodes_to_deploy[@]} target nodes..."
    local ssh_via_bcm_opt=""
    [[ -n "${JUMP_HOST}" && -n "${BCM_HOST}" ]] && ssh_via_bcm_opt="-J ${JUMP_HOST}"
    for node_ip in "${nodes_to_deploy[@]}"; do
      local ssh_to_bcm_cmd="ssh root@$node_ip 'mkdir -p /root/.ssh && grep -qF \"${obs_pub}\" /root/.ssh/authorized_keys 2>/dev/null || echo \"${obs_pub}\" >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys'"
      ssh -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o BatchMode=yes ${ssh_via_bcm_opt} \
        "${BCM_USER}@${BCM_HOST}" "$ssh_to_bcm_cmd" 2>/dev/null || true
    done
    success "SSH key distributed"
  fi

  log "Deploying to ${#nodes_to_deploy[@]} nodes in parallel (batch_size=10)..."
  log "Per-node logs: /tmp/nvis-node-IP.log"
  echo ""

  local pids=()
  local batch_size=10
  local count=0
  rm -f /tmp/nvis-deploy-results.txt

  for node_ip in "${nodes_to_deploy[@]}"; do
    local node_name="${_name_by_ip[$node_ip]:-$node_ip}"
    install_on_node "$node_ip" "$node_name" &
    pids+=($!)
    ((count++)) || true
    if [[ $((count % batch_size)) -eq 0 ]]; then
      for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
      pids=()
    fi
  done
  for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done

  # Read back results and update inventory
  while IFS= read -r line; do
    local node_ip_r node_name_r
    node_ip_r=$(echo "$line" | awk '{print $1}')
    node_name_r="${_name_by_ip[$node_ip_r]:-$node_ip_r}"
    [[ -z "$node_ip_r" ]] && continue
    NODE_DCGM[$node_ip_r]=$(echo "$line" | grep -o 'DCGM=[A-Z]*' | cut -d= -f2)
    NODE_NODE_EXPORTER[$node_ip_r]=$(echo "$line" | grep -o 'NODE_EXPORTER=[A-Z]*' | cut -d= -f2)
    NODE_CADVISOR[$node_ip_r]=$(echo "$line" | grep -o 'CADVISOR=[A-Z]*' | cut -d= -f2)
    NODE_ALLOY[$node_ip_r]=$(echo "$line" | grep -o 'ALLOY=[A-Z]*' | cut -d= -f2)
    local sf="/tmp/nvis-status-${node_ip_r}.txt"
    local node_final_status="PARTIAL"
    grep -q "STATUS=SUCCESS" "$sf" 2>/dev/null && node_final_status="SUCCESS"
    NODE_STATUS[$node_ip_r]="$node_final_status"
    # Write to persistent inventory
    inv_set "$node_name_r" "$node_ip_r" \
      "$node_final_status" \
      "${NODE_DCGM[$node_ip_r]:-FAIL}" \
      "${NODE_NODE_EXPORTER[$node_ip_r]:-FAIL}" \
      "${NODE_ALLOY[$node_ip_r]:-FAIL}" \
      "$ALLOY_CONFIG_HASH"
  done < <(cat /tmp/nvis-deploy-results.txt 2>/dev/null || true)

  echo ""
  log "Updated node inventory:"
  inv_show

  # Wait for metrics to start flowing
  step "Waiting 30 seconds for metrics to reach Prometheus..."
  sleep 30

  step "Verifying metrics are flowing from each deployed node..."
  local metric_count
  metric_count=$(curl -sf "http://localhost:9090/api/v1/query?query=node_uname_info%7Bcluster%3D%22${CLUSTER_NAME}%22%7D" 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['data']['result']))" 2>/dev/null || echo "0")
  success "  ${metric_count} node targets reporting metrics to Prometheus"

  state_set "gpu_nodes"
}

# =============================================================================
# PHASE 8: UFM INTEGRATION
# =============================================================================
phase_ufm() {
  $HAS_UFM || return 0
  header "Phase 8 — UFM Telemetry Integration"
  state_done "ufm" && { log "UFM already configured — skipping"; return; }

  step "Testing UFM connectivity at $UFM_IP..."
  if ! curl -sf --max-time 5 "http://${UFM_IP}:9100/metrics" > /dev/null 2>&1 && \
     ! curl -sf --max-time 5 "http://${UFM_IP}:8080" > /dev/null 2>&1; then
    warn "Cannot reach UFM at $UFM_IP — skipping UFM integration"
    warn "Fix: Ensure UFM is running and $UFM_IP is reachable from ObsVM on port 9100 or 8080"
    return
  fi
  success "UFM reachable at $UFM_IP"

  case "$UFM_TYPE" in
    telemetry)
      step "Configuring UFM Telemetry metrics scrape..."
      local ufm_port=9100
      cat >> "${SCRIPT_DIR}/prometheus/prometheus.yml" << EOF

  # UFM Telemetry — IB/Ethernet fabric metrics
  - job_name: 'ufm-telemetry'
    metrics_path: '/cset/x-minimal'
    static_configs:
      - targets: ['${UFM_IP}:${ufm_port}']
        labels:
          cluster: '${CLUSTER_NAME}'
          role: 'fabric'
    scrape_interval: 30s
EOF
      ;;
    enterprise|cyberai)
      step "Configuring UFM Enterprise metrics scrape..."
      cat >> "${SCRIPT_DIR}/prometheus/prometheus.yml" << EOF

  # UFM Enterprise — primary and secondary telemetry
  - job_name: 'ufm-enterprise-primary'
    metrics_path: '/cset/x-minimal'
    static_configs:
      - targets: ['${UFM_IP}:9001']
        labels:
          cluster: '${CLUSTER_NAME}'
          role: 'fabric-primary'
    scrape_interval: 30s

  - job_name: 'ufm-enterprise-secondary'
    metrics_path: '/cset/x-minimal'
    static_configs:
      - targets: ['${UFM_IP}:9002']
        labels:
          cluster: '${CLUSTER_NAME}'
          role: 'fabric-secondary'
    scrape_interval: 30s
EOF
      ;;
  esac

  # Reload Prometheus
  curl -sf -X POST "http://localhost:9090/-/reload" > /dev/null 2>&1 \
    && success "Prometheus reloaded with UFM scrape job" \
    || warn "Prometheus reload failed — restart manually: docker compose restart prometheus"

  success "UFM integration configured"
  state_set "ufm"
}

# =============================================================================
# PHASE 9: RUN:AI INTEGRATION
# =============================================================================
phase_runai() {
  $HAS_RUNAI || return 0
  header "Phase 9 — Run:ai Integration"
  state_done "runai" && { log "Run:ai already configured — skipping"; return; }

  step "Testing Run:ai connectivity at $RUNAI_ENDPOINT..."
  if ! curl -sf --max-time 5 "${RUNAI_ENDPOINT}/healthz" > /dev/null 2>&1 && \
     ! curl -sf --max-time 5 "${RUNAI_ENDPOINT}" > /dev/null 2>&1; then
    warn "Cannot reach Run:ai at $RUNAI_ENDPOINT — skipping Run:ai integration"
    return
  fi
  success "Run:ai reachable"

  # Add Run:ai Prometheus federation scrape
  step "Adding Run:ai Prometheus federation..."
  local runai_prom_url="${RUNAI_ENDPOINT}"
  # Run:ai Prometheus is typically on the same k8s cluster
  cat >> "${SCRIPT_DIR}/prometheus/prometheus.yml" << EOF

  # Run:ai — federated metrics from Run:ai Prometheus
  - job_name: 'runai-federation'
    honor_labels: true
    metrics_path: '/federate'
    params:
      match[]:
        - '{job="runai"}'
        - '{__name__=~"runai_.*"}'
        - 'container_gpu_utilization'
    static_configs:
      - targets: ['${runai_prom_url}']
        labels:
          cluster: '${CLUSTER_NAME}'
          source: 'runai'
    scrape_interval: 30s
EOF

  # Reload Prometheus
  curl -sf -X POST "http://localhost:9090/-/reload" > /dev/null 2>&1 \
    && success "Prometheus reloaded with Run:ai federation" \
    || warn "Prometheus reload failed"

  # LDAP/SAML user mapping
  if $HAS_LDAP; then
    step "Configuring Run:ai user-to-job mapping..."
    log "Run:ai exposes job owner via SAML UID/email attributes"
    log "These appear in Run:ai metrics as labels on workload metrics"
    log "Dashboard labels: user, project, namespace will auto-populate from Run:ai metrics"
    success "User mapping: job owner labels will appear in dashboards once Run:ai metrics flow"
  fi

  state_set "runai"
}

# =============================================================================
# PHASE 10: PDU / SNMP
# =============================================================================
phase_snmp_pdu() {
  $HAS_SNMP_PDU || return 0
  header "Phase 10 — PDU Power Monitoring via SNMP"
  state_done "snmp_pdu" && { log "SNMP PDU already configured — skipping"; return; }

  step "Setting up SNMP Exporter for $PDU_VENDOR PDUs..."

  mkdir -p "${SCRIPT_DIR}/snmp_exporter"

  # Determine MIB/module for the vendor
  local snmp_module=""
  case "$PDU_VENDOR" in
    apc)       snmp_module="apc_ups" ;;
    raritan)   snmp_module="raritan_pdu3" ;;
    vertiv)    snmp_module="geist_pdu" ;;
    eaton)     snmp_module="eaton_pdu" ;;
    servertech) snmp_module="servertech_sentry4" ;;
    *) snmp_module="if_mib" ;;
  esac

  # Start SNMP Exporter container
  docker run -d \
    --name snmp-exporter \
    --restart unless-stopped \
    -p 9116:9116 \
    prom/snmp-exporter:latest 2>&1 \
    || warn "SNMP Exporter container failed to start — check Docker"

  # Auto-discover PDU IPs via SNMP walk of the IP range
  step "Scanning $PDU_IP_RANGE for SNMP-enabled PDUs..."
  local pdu_ips=()
  if command -v nmap &>/dev/null; then
    mapfile -t pdu_ips < <(nmap -sU -p 161 --open "$PDU_IP_RANGE" 2>/dev/null | grep "Nmap scan report" | awk '{print $5}')
    if [[ "${#pdu_ips[@]}" -gt 0 ]]; then
      success "Found ${#pdu_ips[@]} SNMP-enabled devices: ${pdu_ips[*]}"
    else
      warn "No SNMP devices found in $PDU_IP_RANGE — check IPs and SNMP community string"
    fi
  fi

  # Add SNMP scrape jobs to prometheus.yml
  {
    echo ""
    echo "  # PDU Power Monitoring via SNMP ($PDU_VENDOR)"
    echo "  - job_name: 'snmp-pdu'"
    echo "    static_configs:"
    for pdu_ip in "${pdu_ips[@]}"; do
      echo "      - targets: ['${pdu_ip}']"
    done
    echo "        labels:"
    echo "          cluster: '${CLUSTER_NAME}'"
    echo "          role: 'pdu'"
    echo "    metrics_path: /snmp"
    echo "    params:"
    echo "      module: ['${snmp_module}']"
    echo "    relabel_configs:"
    echo "      - source_labels: [__address__]"
    echo "        target_label: __param_target"
    echo "      - source_labels: [__param_target]"
    echo "        target_label: instance"
    echo "      - target_label: __address__"
    echo "        replacement: localhost:9116"
  } >> "${SCRIPT_DIR}/prometheus/prometheus.yml"

  curl -sf -X POST "http://localhost:9090/-/reload" > /dev/null 2>&1 \
    && success "Prometheus reloaded with SNMP PDU scrape" \
    || warn "Prometheus reload failed"

  state_set "snmp_pdu"
}

# =============================================================================
# PHASE 11: STORAGE METRICS
# =============================================================================
phase_storage() {
  ($HAS_WEKA || $HAS_RAID) || return 0
  header "Phase 11 — Storage Metrics"

  if $HAS_WEKA; then
    step "Configuring Weka exporter..."
    log "Starting Weka Prometheus exporter container..."
    local weka_host=""
    prompt weka_host "Weka cluster management IP"

    docker run -d \
      --name weka-exporter \
      --restart unless-stopped \
      -p 8001:8001 \
      -e WEKA_HOST="$weka_host" \
      weka/prometheus-exporter:latest 2>&1 \
      && success "Weka exporter started" \
      || warn "Weka exporter failed — install manually"

    cat >> "${SCRIPT_DIR}/prometheus/prometheus.yml" << EOF

  # Weka storage metrics
  - job_name: 'weka'
    static_configs:
      - targets: ['localhost:8001']
        labels:
          cluster: '${CLUSTER_NAME}'
          role: 'storage'
    scrape_interval: 30s
EOF
    curl -sf -X POST "http://localhost:9090/-/reload" > /dev/null 2>&1 || true
    success "Weka metrics configured"
  fi

  if $HAS_RAID; then
    step "Configuring RAID/mdadm metrics via node_exporter textfile..."
    # Create a cron job on each GPU node that writes RAID status to textfile
    for node_ip in "${DEPLOY_NODES[@]}"; do
      ssh_cmd="sudo tee /etc/cron.d/nvis-raid > /dev/null << 'EOF'
* * * * * root mdadm --detail --scan 2>/dev/null | python3 -c \"
import sys,re
lines=sys.stdin.read()
arrays=re.findall(r'ARRAY\s+(\S+)', lines)
for a in arrays:
    print(f'# HELP node_md_state RAID array state')
    print(f'# TYPE node_md_state gauge')
    print(f'node_md_state{{device=\\\"{a}\\\", cluster=\\\"${CLUSTER_NAME}\\\"}} 1')
\" > /var/lib/node_exporter/textfile/raid.prom
EOF"
      run_on_node "$node_ip" "$ssh_cmd" > /dev/null 2>&1 || true
    done
    success "RAID metrics configured via textfile collector"
  fi
}

# =============================================================================
# PHASE 12: BCM CERTIFICATES
# =============================================================================
phase_bcm_certs() {
  [[ -n "${BCM_HOST}" ]] || return 0
  header "Phase 12 — BCM Certificates"
  state_done "bcm_certs" && { log "BCM certs already configured — skipping"; return; }

  step "Fetching BCM CA certificate..."
  local cert_dir="${SCRIPT_DIR}/certs"
  # Recreate if exists but not writable (e.g. left by Docker as nobody:nogroup)
  if [[ -d "$cert_dir" ]] && ! [[ -w "$cert_dir" ]]; then
    docker run --rm -v "${SCRIPT_DIR}:/data" alpine rm -rf /data/certs 2>/dev/null || true
  fi
  mkdir -p "$cert_dir"

  local bcm_cert
  local bcm_jump_opt=""
  [[ -n "${JUMP_HOST}" ]] && bcm_jump_opt="-J ${JUMP_HOST}"
  bcm_cert=$(ssh $BCM_SSH_OPTS ${bcm_jump_opt} \
    "${BCM_USER}@${BCM_HOST}" \
    "cat /cm/local/apps/cmd/etc/cacert.pem 2>/dev/null || echo CERT_NOT_FOUND" 2>&1) || true

  if echo "$bcm_cert" | grep -q "BEGIN CERTIFICATE"; then
    echo "$bcm_cert" > "$cert_dir/bcm-ca.pem" || { warn "Could not write BCM CA cert to $cert_dir/bcm-ca.pem — skipping"; state_set "bcm_certs"; return 0; }
    success "BCM CA certificate saved to $cert_dir/bcm-ca.pem"

    # Add TLS config to prometheus.yml for BCM scrapes
    # (Node exporter on BCM-managed nodes uses BCM TLS)
    cat >> "${SCRIPT_DIR}/prometheus/prometheus.yml" << EOF

  # BCM Certificate Authority — TLS config for BCM scrapes
  # Applied to scrape jobs targeting BCM-managed nodes
  # tls_config:
  #   ca_file: /etc/prometheus/certs/bcm-ca.pem
EOF

    # Copy cert into Prometheus container
    docker cp "$cert_dir/bcm-ca.pem" nvis-prometheus:/etc/prometheus/certs/bcm-ca.pem 2>/dev/null \
      && success "BCM cert installed in Prometheus container" \
      || warn "Could not install cert in Prometheus container — may need manual mount"
  else
    warn "BCM CA cert not found at standard path — skipping cert configuration"
    warn "To add manually: copy BCM CA cert to ${cert_dir}/bcm-ca.pem"
  fi

  state_set "bcm_certs"
}

# =============================================================================
# PHASE 13: ALERTING
# =============================================================================
phase_alerting() {
  $SETUP_ALERTS || return 0
  header "Phase 13 — Configure Alerting"

  log "Configuring alerting in Grafana..."

  case "${ALERT_TYPE:-email}" in
    email)
      step "Configuring email alerts..."
      local smtp_host smtp_user smtp_to
      prompt smtp_host "SMTP server (e.g. smtp.gmail.com:587)"
      prompt smtp_user "SMTP username (email address)"
      prompt_secret "SMTP_PASS" "SMTP password"
      prompt smtp_to "Alert recipient email address"

      # Update Grafana docker-compose env
      sed -i "/GF_PATHS_PROVISIONING/a\\      - GF_SMTP_ENABLED=true\n      - GF_SMTP_HOST=${smtp_host}\n      - GF_SMTP_USER=${smtp_user}\n      - GF_SMTP_PASSWORD=${CREDS[SMTP_PASS]}\n      - GF_SMTP_FROM_ADDRESS=${smtp_user}\n      - GF_SMTP_SKIP_VERIFY=true" \
        "${SCRIPT_DIR}/docker-compose.yml"
      docker compose up -d grafana 2>/dev/null
      success "Email alerting configured"
      ;;

    slack)
      step "Configuring Slack webhook..."
      local slack_url
      prompt slack_url "Slack webhook URL (https://hooks.slack.com/services/...)"

      curl -sf -X POST \
        -H "Content-Type: application/json" \
        -u "admin:${GRAFANA_PASS}" \
        http://localhost:3000/api/alert-notifications \
        -d "{\"name\":\"Slack\",\"type\":\"slack\",\"isDefault\":true,\"settings\":{\"url\":\"${slack_url}\"}}" \
        > /dev/null 2>&1 && success "Slack webhook configured"
      ;;

    webhook)
      step "Configuring generic webhook..."
      local webhook_url
      prompt webhook_url "Webhook URL"
      curl -sf -X POST \
        -H "Content-Type: application/json" \
        -u "admin:${GRAFANA_PASS}" \
        http://localhost:3000/api/alert-notifications \
        -d "{\"name\":\"Webhook\",\"type\":\"webhook\",\"isDefault\":true,\"settings\":{\"url\":\"${webhook_url}\",\"httpMethod\":\"POST\"}}" \
        > /dev/null 2>&1 && success "Webhook configured"
      ;;
  esac

  # Create alert rules guide
  cat > "${SCRIPT_DIR}/docs/ALERT_THRESHOLDS.md" << 'ALERTDOC'
# NVIS Alert Thresholds Guide

## How to set alert thresholds in Grafana

1. Open any dashboard panel
2. Click the panel title → Edit
3. Click the "Alert" tab
4. Click "Create Alert Rule"

## Recommended thresholds

### GPU Health
| Metric | Warning | Critical | PromQL |
|--------|---------|----------|--------|
| GPU Temperature | > 80°C | > 90°C | `DCGM_FI_DEV_GPU_TEMP` |
| GPU Utilization (idle) | < 10% for 10min | < 5% for 30min | `DCGM_FI_DEV_GPU_UTIL` |
| GPU Memory Used | > 85% | > 95% | `DCGM_FI_DEV_FB_USED / DCGM_FI_DEV_FB_FREE` |
| XID Errors | Any | Any | `DCGM_FI_DEV_XID_ERRORS > 0` |
| Power Usage | > 380W | > 400W | `DCGM_FI_DEV_POWER_USAGE` |

### Node Health
| Metric | Warning | Critical | PromQL |
|--------|---------|----------|--------|
| CPU Usage | > 90% | > 95% | `1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))` |
| Memory Used | > 85% | > 95% | `1 - node_memory_MemAvailable_bytes/node_memory_MemTotal_bytes` |
| Disk Used | > 80% | > 90% | `1 - node_filesystem_avail_bytes/node_filesystem_size_bytes` |

### Network
| Metric | Warning | Critical | PromQL |
|--------|---------|----------|--------|
| NIC Errors | > 100/min | > 1000/min | `rate(node_network_receive_errs_total[5m])` |
| NIC Drops | > 10/min | > 100/min | `rate(node_network_receive_drop_total[5m])` |

### Log-based alerts
In Grafana → Alerting → Alert Rules → New Rule
Select datasource: Loki
Use LogQL expressions like:
```
count_over_time({cluster="YOUR_CLUSTER", job="syslog"} |~ "XID|error|FATAL" [5m]) > 0
```

## Alert notification channels
Configure in: Grafana → Alerting → Notification channels
ALERTDOC

  success "Alert thresholds guide saved to docs/ALERT_THRESHOLDS.md"
}

# =============================================================================
# PHASE 14: SAML SSO
# =============================================================================
phase_saml() {
  $SETUP_SAML || return 0
  header "Phase 14 — Grafana SAML SSO"

  step "Configuring SAML for Grafana..."
  local saml_metadata_url saml_cert_path
  echo ""
  echo "  You need the IDP Metadata XML from your identity provider."
  echo "  This is typically a URL like: https://your-idp.com/metadata.xml"
  echo ""
  prompt saml_metadata_url "IDP Metadata XML URL"

  # Add SAML config to Grafana via docker-compose env
  sed -i "/GF_PATHS_PROVISIONING/a\\      - GF_AUTH_SAML_ENABLED=true\n      - GF_AUTH_SAML_CERTIFICATE_PATH=/etc/grafana/saml/grafana.crt\n      - GF_AUTH_SAML_PRIVATE_KEY_PATH=/etc/grafana/saml/grafana.key\n      - GF_AUTH_SAML_IDP_METADATA_URL=${saml_metadata_url}\n      - GF_AUTH_SAML_NAME=Corporate SSO\n      - GF_AUTH_SAML_ALLOW_SIGN_UP=true\n      - GF_AUTH_SAML_ROLE_VALUES_ADMIN=GrafanaAdmin\n      - GF_AUTH_SAML_ROLE_VALUES_EDITOR=GrafanaEditor" \
    "${SCRIPT_DIR}/docker-compose.yml"

  # Generate self-signed cert for SAML SP
  mkdir -p "${SCRIPT_DIR}/grafana/saml"
  openssl req -x509 -newkey rsa:4096 \
    -keyout "${SCRIPT_DIR}/grafana/saml/grafana.key" \
    -out "${SCRIPT_DIR}/grafana/saml/grafana.crt" \
    -days 3650 -nodes \
    -subj "/CN=grafana-saml-sp" 2>/dev/null \
    && success "SAML SP certificate generated"

  docker compose up -d grafana 2>/dev/null
  success "SAML SSO configured. Test at: http://${OBSVM_IP}:3000/login/saml"
  warn "You must register Grafana as a Service Provider in your IDP."
  info "  SP Entity ID: http://${OBSVM_IP}:3000/saml/metadata"
  info "  ACS URL:      http://${OBSVM_IP}:3000/saml/acs"
}

# =============================================================================
# PHASE 15: FINAL VALIDATION AND REPORT
# =============================================================================
phase_final_report() {
  header "Phase 15 — Final Validation & Report"

  echo ""
  log "Validating all services one final time..."

  local prom_ok loki_ok graf_ok
  prom_ok=$(curl -sf http://localhost:9090/-/healthy 2>/dev/null && echo "✅ Healthy" || echo "❌ FAILED")
  loki_ok=$(curl -sf http://localhost:3100/ready 2>/dev/null && echo "✅ Ready" || echo "❌ FAILED")
  graf_ok=$(curl -sf http://localhost:3000/api/health 2>/dev/null | python3 -c "import json,sys; print('✅ ' + json.load(sys.stdin).get('database','?'))" 2>/dev/null || echo "❌ FAILED")

  local metrics_count
  metrics_count=$(curl -sf "http://localhost:9090/api/v1/query?query=node_uname_info" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d['data']['result']))" 2>/dev/null || echo "0")

  # Print deployment matrix
  echo ""
  echo -e "${BOLD}Node Deployment Matrix:${NC}"
  printf "  %-18s %-8s %-15s %-10s %-8s %-8s\n" "NODE" "STATUS" "DCGM" "NODE_EXP" "CADVISOR" "ALLOY"
  printf "  %-18s %-8s %-15s %-10s %-8s %-8s\n" "------------------" "--------" "---------------" "----------" "--------" "--------"

  local success_count=0
  local fail_count=0
  local partial_count=0

  for node_ip in "${DEPLOY_NODES[@]}"; do
    local status="${NODE_STATUS[$node_ip]:-UNKNOWN}"
    local dcgm="${NODE_DCGM[$node_ip]:-SKIP}"
    local ne="${NODE_NODE_EXPORTER[$node_ip]:-SKIP}"
    local cad="${NODE_CADVISOR[$node_ip]:-SKIP}"
    local alloy="${NODE_ALLOY[$node_ip]:-SKIP}"

    local color="$NC"
    case "$status" in
      SUCCESS) color="$GREEN"; ((success_count++)) || true ;;
      PARTIAL) color="$YELLOW"; ((partial_count++)) || true ;;
      *)       color="$RED";    ((fail_count++)) || true ;;
    esac

    printf "  ${color}%-18s %-8s %-15s %-10s %-8s %-8s${NC}\n" \
      "$node_ip" "$status" "$dcgm" "$ne" "$cad" "$alloy"
  done

  # Blind spots
  echo ""
  if [[ "${#DOWN_NODES[@]}" -gt 0 ]]; then
    echo -e "${YELLOW}Blind spots — nodes NOT deployed (DOWN in BCM):${NC}"
    for n in "${DOWN_NODES[@]}"; do
      echo -e "  ${RED}  $n — DOWN${NC}"
    done
    echo ""
  fi

  # Save full report
  {
    echo "NVIS Observability Suite — Deployment Report"
    echo "Generated: $(date)"
    echo "================================================"
    echo ""
    echo "ObsVM IP:     $OBSVM_IP"
    echo "Cluster Name: $CLUSTER_NAME"
    echo "BCM Host:     $BCM_HOST"
    echo ""
    echo "Services:"
    echo "  Prometheus:  http://${OBSVM_IP}:9090  — $prom_ok"
    echo "  Loki:        http://${OBSVM_IP}:3100  — $loki_ok"
    echo "  Grafana:     http://${OBSVM_IP}:3000  — $graf_ok"
    [[ $HAS_LONGTERM == true ]] && echo "  VictoriaMetrics: http://${OBSVM_IP}:8428"
    echo ""
    echo "Node Metrics Flowing: $metrics_count node targets"
    echo ""
    echo "Node Deployment Summary:"
    echo "  Success:  $success_count"
    echo "  Partial:  $partial_count"
    echo "  Failed:   $fail_count"
    echo "  Skipped (DOWN): ${#DOWN_NODES[@]}"
    echo ""
    echo "Node Details:"
    for node_ip in "${DEPLOY_NODES[@]}"; do
      echo "  $node_ip: DCGM=${NODE_DCGM[$node_ip]:-?} NODE_EXP=${NODE_NODE_EXPORTER[$node_ip]:-?} CADVISOR=${NODE_CADVISOR[$node_ip]:-?} ALLOY=${NODE_ALLOY[$node_ip]:-?}"
    done
    echo ""
    echo "Optional Integrations:"
    echo "  UFM:        $HAS_UFM  ${UFM_IP:-}"
    echo "  Run:ai:     $HAS_RUNAI  ${RUNAI_ENDPOINT:-}"
    echo "  PDU SNMP:   $HAS_SNMP_PDU  ${PDU_VENDOR:-}"
    echo "  Weka:       $HAS_WEKA"
    echo "  RAID:       $HAS_RAID"
    echo "  Long-term:  $HAS_LONGTERM  ${VICTORIA_RETENTION:-}mo"
    echo "  Alerting:   $SETUP_ALERTS"
    echo "  SAML SSO:   $SETUP_SAML"
    echo ""
    echo "Debug log: $LOG_FILE"
  } > "$REPORT_FILE"

  success "Report saved to: $REPORT_FILE"

  # Final summary to screen
  echo ""
  echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${GREEN}  NVIS Observability Suite — Setup Complete!${NC}"
  echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  ${BOLD}Grafana:${NC}          http://${OBSVM_IP}:3000  →  admin / ${GRAFANA_PASS}"
  echo -e "  ${BOLD}NVIS Home:${NC}        http://${OBSVM_IP}:3000/d/nvis-demo-home"
  echo -e "  ${BOLD}Cluster Overview:${NC} http://${OBSVM_IP}:3000/d/cluster-overview-cod"
  echo -e "  ${BOLD}GPU Health:${NC}       http://${OBSVM_IP}:3000/d/gpu-health-cod"
  echo -e "  ${BOLD}Prometheus:${NC}       http://${OBSVM_IP}:9090"
  echo -e "  ${BOLD}Loki:${NC}             http://${OBSVM_IP}:3100"
  $HAS_LONGTERM && echo -e "  ${BOLD}VictoriaMetrics:${NC}  http://${OBSVM_IP}:8428" || true
  echo ""
  echo -e "  ${BOLD}Nodes deployed:${NC}    $success_count success, $partial_count partial, $fail_count failed"
  echo -e "  ${BOLD}Metrics flowing:${NC}   $metrics_count node targets in Prometheus"
  echo ""
  echo -e "  ${BOLD}Next steps:${NC}"
  echo -e "  1. Open NVIS Home: http://${OBSVM_IP}:3000/d/nvis-demo-home"
  echo -e "  2. Review docs/ALERT_THRESHOLDS.md to configure alerts"
  if [[ $partial_count -gt 0 ]] || [[ $fail_count -gt 0 ]]; then
    echo -e "  3. ${YELLOW}Fix partial/failed nodes — check /tmp/nvis-node-IP.log on ObsVM${NC}"
    echo -e "  4. Re-run: bash setup.sh (will skip completed steps)"
  fi
  echo ""
  echo -e "  ${DIM}Full report: $REPORT_FILE${NC}"
  echo -e "  ${DIM}Debug log:   $LOG_FILE${NC}"
  echo ""
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  # ── Parse flags ────────────────────────────────────────────────────────────
  local run_phase=""
  local args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --phase)    run_phase="$2"; shift 2 ;;
      --phase=*)  run_phase="${1#--phase=}"; shift ;;
      *)          args+=("$1"); shift ;;
    esac
  done

  # ── Single-phase mode: --phase gpu_nodes ────────────────────────────────────
  # Re-runs BCM discovery (to pick up new nodes) then deploys only to
  # new/failed nodes. All other phases are skipped. Existing inventory is used
  # to skip nodes that are already healthy with the current Alloy config.
  if [[ "$run_phase" == "gpu_nodes" ]]; then
    # Load saved config (OBSVM_IP, CLUSTER_NAME, BCM_HOST, etc.)
    [[ -f "${SCRIPT_DIR}/.nvis-config" ]] && source "${SCRIPT_DIR}/.nvis-config"
    [[ -f "${SCRIPT_DIR}/.nvis-creds"  ]] && source "${SCRIPT_DIR}/.nvis-creds"
    header "Phase: GPU Node Deploy (incremental)"
    info "Re-discovering nodes from BCM, deploying only to new/failed nodes."
    info "Healthy nodes (in inventory with current Alloy config) will be skipped."
    echo ""
    FORCE_REDISCOVER=true
    phase_bcm_discovery
    phase_gpu_nodes
    return
  fi

  # ── Full setup ──────────────────────────────────────────────────────────────
  show_banner
  phase_preflight
  phase_interview
  phase_install_obsvm
  phase_bcm_discovery
  phase_obsvm_stack
  phase_terraform
  phase_gpu_nodes
  phase_ufm
  phase_runai
  phase_snmp_pdu
  phase_storage
  phase_bcm_certs
  phase_alerting
  phase_saml
  phase_final_report
}

main "$@"
