#!/bin/bash
# Startup script for Moltbot in Cloudflare Sandbox
# This script:
# 1. Restores config from R2 backup if available
# 2. Configures moltbot from environment variables
# 3. Starts a background sync to backup config to R2
# 4. Starts the gateway

set -e

# Check whether gateway port is already reachable. Process-name checks alone are unreliable
# after failed upgrades (stale processes can remain while the port is down).
is_gateway_port_open() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 1 bash -c 'cat < /dev/null > /dev/tcp/127.0.0.1/18789' >/dev/null 2>&1
        return $?
    fi
    bash -c 'cat < /dev/null > /dev/tcp/127.0.0.1/18789' >/dev/null 2>&1
    return $?
}

if is_gateway_port_open; then
    echo "Gateway port 18789 is already reachable, exiting."
    exit 0
fi

if pgrep -f "openclaw gateway|openclaw-gateway" >/dev/null 2>&1; then
    echo "Found stale openclaw gateway process without listening port; terminating it."
    pkill -f "openclaw gateway|openclaw-gateway" >/dev/null 2>&1 || true
    sleep 1
fi

# Paths (clawdbot paths are used internally - upstream hasn't renamed yet)
CONFIG_DIR="/root/.clawdbot"
CONFIG_FILE="$CONFIG_DIR/clawdbot.json"
TEMPLATE_DIR="/root/.clawdbot-templates"
TEMPLATE_FILE="$TEMPLATE_DIR/moltbot.json.template"
BACKUP_DIR="/data/moltbot"

echo "Config directory: $CONFIG_DIR"
echo "Backup directory: $BACKUP_DIR"
# Create config directory
mkdir -p "$CONFIG_DIR"

# ============================================================
# RESTORE FROM R2 BACKUP
# ============================================================
# Check if R2 backup exists by looking for clawdbot.json
# The BACKUP_DIR may exist but be empty if R2 was just mounted
# Note: backup structure is $BACKUP_DIR/clawdbot/, $BACKUP_DIR/skills/, and $BACKUP_DIR/openclaw-home/

# Helper function to check if R2 backup is newer than local
should_restore_from_r2() {
    local R2_SYNC_FILE="$BACKUP_DIR/.last-sync"
    local LOCAL_SYNC_FILE="$CONFIG_DIR/.last-sync"
    
    # If no R2 sync timestamp, don't restore
    if [ ! -f "$R2_SYNC_FILE" ]; then
        echo "No R2 sync timestamp found, skipping restore"
        return 1
    fi
    
    # If no local sync timestamp, restore from R2
    if [ ! -f "$LOCAL_SYNC_FILE" ]; then
        echo "No local sync timestamp, will restore from R2"
        return 0
    fi
    
    # Compare timestamps
    R2_TIME=$(cat "$R2_SYNC_FILE" 2>/dev/null)
    LOCAL_TIME=$(cat "$LOCAL_SYNC_FILE" 2>/dev/null)
    
    echo "R2 last sync: $R2_TIME"
    echo "Local last sync: $LOCAL_TIME"
    
    # Convert to epoch seconds for comparison
    R2_EPOCH=$(date -d "$R2_TIME" +%s 2>/dev/null || echo "0")
    LOCAL_EPOCH=$(date -d "$LOCAL_TIME" +%s 2>/dev/null || echo "0")
    
    if [ "$R2_EPOCH" -gt "$LOCAL_EPOCH" ]; then
        echo "R2 backup is newer, will restore"
        return 0
    else
        echo "Local data is newer or same, skipping restore"
        return 1
    fi
}

if [ -f "$BACKUP_DIR/clawdbot/clawdbot.json" ]; then
    if should_restore_from_r2; then
        echo "Restoring from R2 backup at $BACKUP_DIR/clawdbot..."
        cp -a "$BACKUP_DIR/clawdbot/." "$CONFIG_DIR/"
        # Copy the sync timestamp to local so we know what version we have
        cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        echo "Restored config from R2 backup"
    fi
elif [ -f "$BACKUP_DIR/clawdbot.json" ]; then
    # Legacy backup format (flat structure)
    if should_restore_from_r2; then
        echo "Restoring from legacy R2 backup at $BACKUP_DIR..."
        cp -a "$BACKUP_DIR/." "$CONFIG_DIR/"
        cp -f "$BACKUP_DIR/.last-sync" "$CONFIG_DIR/.last-sync" 2>/dev/null || true
        echo "Restored config from legacy R2 backup"
    fi
elif [ -d "$BACKUP_DIR" ]; then
    echo "R2 mounted at $BACKUP_DIR but no backup data found yet"
else
    echo "R2 not mounted, starting fresh"
fi

# Restore skills and OpenClaw OAuth data from R2 backup if available (only if R2 is newer)
SKILLS_DIR="/root/clawd/skills"
OPENCLAW_HOME_DIR="/root/.openclaw"
if [ -d "$BACKUP_DIR/skills" ] && [ "$(ls -A $BACKUP_DIR/skills 2>/dev/null)" ]; then
    if should_restore_from_r2; then
        echo "Restoring skills from $BACKUP_DIR/skills..."
        mkdir -p "$SKILLS_DIR"
        cp -a "$BACKUP_DIR/skills/." "$SKILLS_DIR/"
        echo "Restored skills from R2 backup"
    fi
fi
if [ -d "$BACKUP_DIR/openclaw-home" ] && [ "$(ls -A $BACKUP_DIR/openclaw-home 2>/dev/null)" ]; then
    if should_restore_from_r2; then
        echo "Restoring OpenClaw home from $BACKUP_DIR/openclaw-home..."
        mkdir -p "$OPENCLAW_HOME_DIR"
        cp -a "$BACKUP_DIR/openclaw-home/." "$OPENCLAW_HOME_DIR/"
        echo "Restored OpenClaw OAuth/state from R2 backup"
    fi
fi

# If config file still doesn't exist, create from template
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, initializing from template..."
    if [ -f "$TEMPLATE_FILE" ]; then
        cp "$TEMPLATE_FILE" "$CONFIG_FILE"
    else
        # Create minimal config if template doesn't exist
        cat > "$CONFIG_FILE" << 'EOFCONFIG'
{
  "agents": {
    "defaults": {
      "workspace": "/root/clawd"
    }
  },
  "gateway": {
    "port": 18789,
    "mode": "local"
  }
}
EOFCONFIG
    fi
else
    echo "Using existing config"
fi

# ============================================================
# UPDATE CONFIG FROM ENVIRONMENT VARIABLES
# ============================================================
node << EOFNODE
const fs = require('fs');

const configPath = '/root/.clawdbot/clawdbot.json';
console.log('Updating config at:', configPath);
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with empty config');
}

// Ensure nested objects exist
config.agents = config.agents || {};
config.agents.defaults = config.agents.defaults || {};
config.agents.defaults.model = config.agents.defaults.model || {};
config.gateway = config.gateway || {};
config.channels = config.channels || {};
config.commands = config.commands || {};

// Clean up any broken anthropic provider config from previous runs
// (older versions didn't include required 'name' field)
if (config.models?.providers?.anthropic?.models) {
    const hasInvalidModels = config.models.providers.anthropic.models.some(m => !m.name);
    if (hasInvalidModels) {
        console.log('Removing broken anthropic provider config (missing model names)');
        delete config.models.providers.anthropic;
    }
}



// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
// Use a valid private CIDR range for trusted proxies.
config.gateway.trustedProxies = ['10.0.0.0/8'];

// Set gateway token if provided
if (process.env.CLAWDBOT_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.CLAWDBOT_GATEWAY_TOKEN;
}

// Allow insecure auth for dev mode
if (process.env.CLAWDBOT_DEV_MODE === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
}

// Telegram configuration (webhook mode for Cloudflare Workers)
if (process.env.TELEGRAM_BOT_TOKEN) {
    config.channels.telegram = config.channels.telegram || {};
    config.channels.telegram.botToken = process.env.TELEGRAM_BOT_TOKEN;
    config.channels.telegram.enabled = true;
    // Webhook mode - required for Cloudflare Workers (no persistent connections)
    // The webhook URL is set via TELEGRAM_WEBHOOK_URL or defaults to worker URL
    const baseWorkerUrl = process.env.WORKER_PUBLIC_URL || process.env.WORKER_URL;
    const webhookUrl = process.env.TELEGRAM_WEBHOOK_URL ||
        (baseWorkerUrl ? baseWorkerUrl.replace(/\/+$/, '') + '/telegram-webhook' : null);
    if (webhookUrl) {
        config.channels.telegram.webhookUrl = webhookUrl;
        config.channels.telegram.webhookPath = '/telegram-webhook';
        // OpenClaw requires webhookSecret when webhookUrl is configured.
        // Reuse explicit TELEGRAM_WEBHOOK_SECRET if provided, otherwise fall back
        // to the gateway token so the value is stable across restarts.
        const webhookSecret = process.env.TELEGRAM_WEBHOOK_SECRET || process.env.CLAWDBOT_GATEWAY_TOKEN;
        if (webhookSecret) {
            config.channels.telegram.webhookSecret = webhookSecret;
        }
        console.log('Telegram webhook URL:', webhookUrl);
    } else {
        console.warn('WARNING: No webhook URL configured. Set TELEGRAM_WEBHOOK_URL, WORKER_PUBLIC_URL, or WORKER_URL');
        console.warn('Telegram may not work correctly without webhook mode in Cloudflare Workers');
    }
}

// Discord configuration
if (process.env.DISCORD_BOT_TOKEN) {
    config.channels.discord = config.channels.discord || {};
    config.channels.discord.token = process.env.DISCORD_BOT_TOKEN;
    config.channels.discord.enabled = true;
    config.channels.discord.dm = config.channels.discord.dm || {};
    config.channels.discord.dm.policy = process.env.DISCORD_DM_POLICY || 'pairing';
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = config.channels.slack || {};
    config.channels.slack.botToken = process.env.SLACK_BOT_TOKEN;
    config.channels.slack.appToken = process.env.SLACK_APP_TOKEN;
    config.channels.slack.enabled = true;
}

// Provider/model configuration:
// Keep this intentionally minimal. New OpenClaw versions may reject custom provider
// schema fields written by older startup scripts.
if (config.models && config.models.providers) {
    delete config.models.providers.openai;
    delete config.models.providers.anthropic;
}

const preferredProvider = (process.env.PREFERRED_PROVIDER || '').toLowerCase();
const gatewayBaseUrl = (process.env.AI_GATEWAY_BASE_URL || '').replace(/\/+$/, '');
const gatewayLooksOpenAI = gatewayBaseUrl.endsWith('/openai');
const stalePrimaryModels = new Set([
    'openai/gpt-5.2',
    'openai/gpt-4.5-preview',
    'anthropic/claude-opus-4-5-20251101',
    'anthropic/claude-sonnet-4-5-20250929',
    'anthropic/claude-haiku-4-5-20251001',
]);
if (stalePrimaryModels.has(config.agents.defaults.model.primary)) {
    delete config.agents.defaults.model.primary;
}

// Only pin the primary model when explicitly requested.
if (preferredProvider === 'openai' || (gatewayBaseUrl && gatewayLooksOpenAI)) {
    config.agents.defaults.model.primary = 'openai/gpt-5';
} else if (preferredProvider === 'anthropic' || (gatewayBaseUrl && !gatewayLooksOpenAI)) {
    config.agents.defaults.model.primary = 'anthropic/claude-opus-4-5';
}

// Write updated config
fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration updated successfully');
EOFNODE

# ============================================================
# START GATEWAY
# ============================================================
# Note: R2 backup sync is handled by the Worker's cron trigger
echo "Starting Moltbot Gateway..."
echo "Gateway will be available on port 18789"

# Clean up stale lock files
rm -f /tmp/clawdbot-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

echo "Dev mode: ${CLAWDBOT_DEV_MODE:-false}"

# Prefer image binary path explicitly to avoid picking up accidental PATH overrides.
OPENCLAW_BIN="/usr/local/bin/openclaw"
if [ ! -x "$OPENCLAW_BIN" ]; then
    OPENCLAW_BIN="$(command -v openclaw || true)"
fi
if [ -z "$OPENCLAW_BIN" ]; then
    echo "ERROR: openclaw binary not found"
    exit 1
fi

# Ensure newer OpenClaw versions read the config file we generate here.
export OPENCLAW_CONFIG_PATH="$CONFIG_FILE"
export CLAWDBOT_CONFIG_PATH="$CONFIG_FILE"

# CLI shape changed across versions:
# - legacy: openclaw gateway --port ...
# - newer:  openclaw gateway run --port ... (or gateway start)
# Detect the supported command form first, then only pass supported flags.
get_help_text() {
    "$OPENCLAW_BIN" "$@" --help 2>&1 || true
}

is_supported_help() {
    local txt="$1"
    if echo "$txt" | grep -qiE 'unknown command|invalid command|unknown option|unknown arguments'; then
        return 1
    fi
    return 0
}

GATEWAY_HELP="$(get_help_text gateway)"
GATEWAY_RUN_HELP="$(get_help_text gateway run)"
GATEWAY_START_HELP="$(get_help_text gateway start)"

GATEWAY_MODE="gateway"
HELP_TEXT="$GATEWAY_HELP"
GATEWAY_ARGS=(gateway)

if is_supported_help "$GATEWAY_RUN_HELP"; then
    GATEWAY_MODE="gateway run"
    HELP_TEXT="$GATEWAY_RUN_HELP"
    GATEWAY_ARGS=(gateway run)
elif is_supported_help "$GATEWAY_START_HELP"; then
    GATEWAY_MODE="gateway start"
    HELP_TEXT="$GATEWAY_START_HELP"
    GATEWAY_ARGS=(gateway start)
fi

echo "Detected gateway command mode: $GATEWAY_MODE"

if echo "$HELP_TEXT" | grep -q -- '--port'; then
    GATEWAY_ARGS+=(--port 18789)
fi

if [ -n "$CLAWDBOT_GATEWAY_TOKEN" ]; then
    if echo "$HELP_TEXT" | grep -q -- '--token'; then
        GATEWAY_ARGS+=(--token "$CLAWDBOT_GATEWAY_TOKEN")
    fi
    echo "Starting gateway with token auth..."
else
    echo "Starting gateway with device pairing (no token)..."
fi

exec "$OPENCLAW_BIN" "${GATEWAY_ARGS[@]}"
