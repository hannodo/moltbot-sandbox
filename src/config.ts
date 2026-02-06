/**
 * Configuration constants for Moltbot Sandbox
 */

/** Port that the Moltbot gateway listens on inside the container */
export const MOLTBOT_PORT = 18789;

/**
 * Port that the OpenClaw Telegram webhook listener binds to inside the container.
 * See OpenClaw Telegram docs (default listener port 8787).
 */
export const TELEGRAM_WEBHOOK_PORT = 8787;

/** Maximum time to wait for Moltbot to start (10 minutes). */
export const STARTUP_TIMEOUT_MS = 600_000;

/** Mount path for R2 persistent storage inside the container */
export const R2_MOUNT_PATH = '/data/moltbot';

/** R2 bucket name for persistent storage */
export const R2_BUCKET_NAME = 'moltbot-data';
