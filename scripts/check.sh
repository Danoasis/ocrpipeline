#!/usr/bin/env bash
set -euo pipefail
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0

ok()   { echo -e "  ${GREEN}✓${NC}  $1"; ((PASS++)) || true; }
fail() { echo -e "  ${RED}✗${NC}  $1"; ((FAIL++)) || true; }
info() { echo -e "  ${BLUE}→${NC}  $1"; }

echo ""
echo "========================================"
echo "  OCR Pipeline — Pre-flight check"
echo "========================================"
echo ""

echo "[ Tools ]"
command -v docker &>/dev/null && ok "docker found" || fail "docker not found"
docker compose version &>/dev/null && ok "docker compose found" || fail "docker compose not found"

echo ""
echo "[ Docker daemon ]"
docker info &>/dev/null && ok "Docker daemon running" || fail "Docker daemon not running"

echo ""
echo "[ Required files ]"
for f in Dockerfile docker-compose.yml requirements.txt main.py app/__init__.py app/config.py app/ocr.py app/llm.py app/validation.py app/pipeline.py api/__init__.py api/main.py api/endpoints.py api/schemas.py static/index.html; do
  [[ -f "$f" ]] && ok "$f" || fail "$f missing"
done

echo ""
echo "[ Environment ]"
[[ -f ".env" ]] && ok ".env exists" || { fail ".env missing"; info "Fix: cp .env.example .env"; }

echo ""
echo "[ Directories ]"
[[ -d "licenses" ]] && ok "licenses/ exists" || fail "licenses/ missing"
[[ -d "results"  ]] && ok "results/ exists"  || fail "results/ missing"

echo ""
echo "========================================"
if (( FAIL == 0 )); then
    echo -e "  ${GREEN}All checks passed.${NC}"
    echo "  Run: docker compose up --build api"
else
    echo -e "  ${RED}${FAIL} check(s) failed.${NC}"
fi
echo "========================================"
