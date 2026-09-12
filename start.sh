#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> OpenWA / WA-CRM startup"

# Node version check
if ! command -v node &>/dev/null; then
  echo "ERROR: Node.js is not installed. Install Node >= 22.13 first."
  exit 1
fi

NODE_MAJOR=$(node -e "console.log(process.version.slice(1).split('.')[0])")
if [ "$NODE_MAJOR" -lt 22 ]; then
  echo "ERROR: Node >= 22 required (found $(node --version))"
  exit 1
fi
echo "==> Node: $(node --version) | npm: $(npm --version)"

# Detect Chrome / Chromium for Puppeteer
CHROME_BIN=""
for candidate in /usr/bin/google-chrome-stable /usr/bin/google-chrome /usr/bin/chromium-browser /usr/bin/chromium /snap/bin/chromium; do
  if [ -x "$candidate" ]; then
    CHROME_BIN="$candidate"
    break
  fi
done

if [ -n "$CHROME_BIN" ]; then
  echo "==> Chrome: $CHROME_BIN"
  export PUPPETEER_EXECUTABLE_PATH="$CHROME_BIN"
else
  echo "WARNING: No Chrome/Chromium found. Puppeteer will download its own."
fi

# Copy .env if not exists
if [ ! -f .env ]; then
  if [ -f .env.minimal ]; then
    cp .env.minimal .env
    echo "==> Created .env from .env.minimal"
  elif [ -f .env.example ]; then
    cp .env.example .env
    echo "==> Created .env from .env.example"
  fi
fi

# Ensure Puppeteer/Chrome settings are in .env
if [ -n "$CHROME_BIN" ]; then
  if grep -q "^PUPPETEER_EXECUTABLE_PATH=" .env 2>/dev/null; then
    sed -i "s|^PUPPETEER_EXECUTABLE_PATH=.*|PUPPETEER_EXECUTABLE_PATH=$CHROME_BIN|" .env
  else
    echo "PUPPETEER_EXECUTABLE_PATH=$CHROME_BIN" >> .env
  fi
fi

# Ensure --no-sandbox flag is in .env (required on most VMs)
if ! grep -q "^PUPPETEER_ARGS=" .env 2>/dev/null; then
  echo "PUPPETEER_ARGS=--no-sandbox,--disable-setuid-sandbox,--disable-dev-shm-usage" >> .env
fi

# Install dependencies if needed
if [ ! -d node_modules ]; then
  echo "==> Installing dependencies..."
  npm install
fi

if [ ! -d dashboard/node_modules ]; then
  echo "==> Installing dashboard dependencies..."
  npm run dashboard:install
fi

# Build API if dist/main is missing or outdated
if [ ! -f dist/main.js ] && [ ! -f dist/main ]; then
  echo "==> Building API..."
  npm run build 2>&1 || { echo "ERROR: API build failed"; exit 1; }
  # NestJS outputs to dist/main.js (not dist/main)
fi

# Handle NestJS output: it creates dist/main.js, not dist/main
MAIN_FILE="dist/main"
if [ ! -f "$MAIN_FILE" ] && [ -f "dist/main.js" ]; then
  MAIN_FILE="dist/main.js"
fi

# Build dashboard if missing
if [ ! -d dashboard/dist ]; then
  echo "==> Building dashboard..."
  npm run dashboard:build 2>&1 || { echo "ERROR: Dashboard build failed"; exit 1; }
fi

# Stop existing PM2 process if running
if pm2 describe wa-crm >/dev/null 2>&1; then
  echo "==> Stopping existing wa-crm process"
  pm2 delete wa-crm
fi

echo "==> Starting PM2 process: wa-crm (entry: $MAIN_FILE)"

PUPPETEER_EXECUTABLE_PATH="${PUPPETEER_EXECUTABLE_PATH:-}" \
pm2 start "$MAIN_FILE" --name wa-crm

pm2 save

echo
echo "WA-CRM (OpenWA) started successfully"
echo "  cwd:   $SCRIPT_DIR"
if [ -n "${CHROME_BIN:-}" ]; then
  echo "  Chrome: $CHROME_BIN"
else
  echo "  Chrome: managed by Puppeteer"
fi
echo
echo "Use: pm2 logs wa-crm"