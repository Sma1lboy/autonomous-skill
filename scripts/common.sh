#!/usr/bin/env bash
# common.sh — Shared utility functions for autonomous-skill scripts.
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
# Layer: shared

die() { echo "ERROR: $*" >&2; exit 1; }
