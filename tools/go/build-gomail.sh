#!/usr/bin/env bash
# M194g (#3287): build GOMAIL.ELF (user/go/gomail, M187c issue #3184) via the
# generic web-app builder, the same way tools/go/build-git.sh wraps GOTGIT.
# The named script is what tools/session.sh's go_app_builder maps GOMAIL.ELF
# to by name convention.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
case "${1:-}" in
    "")     bash "$REPO/tools/go/build-web.sh" gomail GOMAIL ;;
    --gate) bash "$REPO/tools/go/build-web.sh" gomail GOMAIL --gate ;;
    *)      echo "usage: build-gomail.sh [--gate]" >&2; exit 2 ;;
esac
