#!/bin/bash
# gstack bootstrap for Claude Code on the web.
#
# Web sessions run in an ephemeral container that is rebuilt each time, so
# anything installed into ~/.claude/skills does not survive. This SessionStart
# hook re-installs gstack on every web session so all /gstack skills (office
# hours, review, ship, qa, investigate, cso, ...) are available in every
# project. Locally you install gstack once by hand, so this hook no-ops there.
#
# Copy this file (and the SessionStart entry in .claude/settings.json) into any
# repo you want gstack available in on the web. It self-detects whether the
# current repo IS gstack or is some other project.
set -euo pipefail

# Only bootstrap in Claude Code on the web. Local machines install gstack once
# into ~/.claude/skills and never need this.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

GSTACK_UPSTREAM="https://github.com/garrytan/gstack.git"

# ---------------------------------------------------------------------------
# Bridge the pre-installed Chromium to the build number gstack's Playwright
# expects. Claude Code on the web ships Chromium under $PLAYWRIGHT_BROWSERS_PATH
# but usually at a different Playwright build number than gstack pins. Without
# this, ./setup tries to download the exact build from cdn.playwright.dev, which
# is not in the web network allowlist (403), and setup aborts before it can
# register the skills. Symlinking the expected build to the installed one lets
# setup's launch check pass with zero network.
bridge_playwright_browser() {
  local pw_dir="${PLAYWRIGHT_BROWSERS_PATH:-}"
  [ -n "$pw_dir" ] && [ -d "$pw_dir" ] || return 0

  local bj="node_modules/playwright-core/browsers.json"
  [ -f "$bj" ] || return 0

  # Revision gstack's playwright wants, e.g. 1208.
  local want
  want=$(grep -A2 '"name": "chromium"' "$bj" | grep '"revision"' | head -1 | grep -oE '[0-9]+' | head -1)
  [ -n "$want" ] || return 0

  # Full Chromium: same layout across builds, so symlink the whole build dir.
  local have_chrome
  have_chrome=$(find "$pw_dir" -maxdepth 3 -type f -path '*chrome-linux/chrome' 2>/dev/null | head -1)
  if [ -n "$have_chrome" ] && [ ! -e "$pw_dir/chromium-$want/chrome-linux/chrome" ]; then
    ln -sfn "${have_chrome%/chrome-linux/chrome}" "$pw_dir/chromium-$want"
  fi

  # Headless shell: the binary/dir layout changed across builds, so point the
  # exact expected path at whichever headless-shell binary is present.
  local have_shell
  have_shell=$(find "$pw_dir" -maxdepth 3 -type f \( -name headless_shell -o -name chrome-headless-shell \) 2>/dev/null | head -1)
  local want_shell="$pw_dir/chromium_headless_shell-$want/chrome-headless-shell-linux64/chrome-headless-shell"
  if [ -n "$have_shell" ] && [ ! -e "$want_shell" ]; then
    mkdir -p "$(dirname "$want_shell")"
    ln -sfn "$have_shell" "$want_shell"
    : > "$pw_dir/chromium_headless_shell-$want/INSTALLATION_COMPLETE" 2>/dev/null || true
  fi
}

# Resolve the gstack source dir: this repo if it IS gstack, else a fresh clone.
if [ -f "./setup" ] && [ -f "./SKILL.md.tmpl" ]; then
  GSTACK_DIR="$(pwd)"
else
  GSTACK_DIR="$HOME/.claude/skills/gstack"
  if [ ! -d "$GSTACK_DIR/.git" ]; then
    git clone --single-branch --depth 1 "$GSTACK_UPSTREAM" "$GSTACK_DIR"
  fi
fi

cd "$GSTACK_DIR"

# Populate node_modules (and browsers.json) before bridging, then let ./setup
# build the binaries and register every skill into ~/.claude/skills.
bun install --frozen-lockfile 2>/dev/null || bun install
bridge_playwright_browser
./setup
