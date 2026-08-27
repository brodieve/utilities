#!/usr/bin/env bash
# Prints the current datetime in ISO 8601 format (UTC).
# Uses only POSIX/BSD-compatible `date` flags so it works unmodified
# on both macOS (BSD date) and Linux (GNU date).
set -euo pipefail

date -u +"%Y-%m-%dT%H:%M:%SZ"
