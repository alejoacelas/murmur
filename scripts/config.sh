#!/usr/bin/env bash
# config.sh — shared constants for all Murmur build/sign/test scripts. Source this.
set -euo pipefail

# Repo root (this file lives in <repo>/scripts). Works whether sourced from bash or zsh.
_murmur_cfg_src="${BASH_SOURCE[0]:-${(%):-%x}}"
MURMUR_REPO="$(cd "$(dirname "$_murmur_cfg_src")/.." && pwd)"

APP_NAME="Murmur"
BUNDLE_ID="com.alejoacelas.Murmur"
CODESIGN_IDENTITY="${MURMUR_CODESIGN_IDENTITY:-Murmur Dev}"

# Stable install path — keep constant across rebuilds so TCC grants persist.
APP_PATH="$MURMUR_REPO/build/$APP_NAME.app"

# Support dir used by the app at runtime (sessions, logs, config, control socket).
SUPPORT_DIR="$HOME/Library/Application Support/$APP_NAME"

# Dedicated code-signing keychain created by make-cert.sh.
MURMUR_KC="$HOME/Library/Keychains/murmur-dev.keychain-db"
MURMUR_KC_PASS="${MURMUR_KC_PASS:-murmur-dev}"

export MURMUR_REPO APP_NAME BUNDLE_ID CODESIGN_IDENTITY APP_PATH SUPPORT_DIR MURMUR_KC MURMUR_KC_PASS
