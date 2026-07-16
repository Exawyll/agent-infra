#!/bin/bash
# import-workflows.sh — Importe tous les workflows n8n depuis n8n-workflows/
# Usage: ./import-workflows.sh [workflow-dir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
WORKFLOW_DIR="${1:-${REPO_ROOT}/n8n-workflows}"
N8N_URL="${N8N_URL:-http://localhost:5678}"
COUNT=0

if [ ! -d "$WORKFLOW_DIR" ]; then
  echo "❌ Workflow directory not found: $WORKFLOW_DIR"
  exit 1
fi

import_workflow() {
  local file="$1"
  local name
  name=$(basename "$file" .json)
  echo "  Importing ${name}..."

  local HTTP_CODE
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${N8N_URL}/api/v1/workflows" \
    -H "Content-Type: application/json" \
    -d @"$file" 2>/dev/null || echo "000")

  if [ "$HTTP_CODE" = "200" ]; then
    echo "    ✅ Imported"
    COUNT=$((COUNT + 1))
  else
    echo "    ⚠️  HTTP ${HTTP_CODE} — may already exist or need manual import"
  fi
}

echo "📋 Importing workflows from ${WORKFLOW_DIR}..."

# Import personal workflows
for wf in "${WORKFLOW_DIR}"/*.json; do
  [ -f "$wf" ] || continue
  import_workflow "$wf"
done

# Also import _pro/ workflows (user discretion)
if [ -d "${WORKFLOW_DIR}/_pro" ]; then
  echo ""
  echo "⚠️  _pro/ directory found — professional workflows (reconnect creds manually)"
  for wf in "${WORKFLOW_DIR}/_pro"/*.json; do
    [ -f "$wf" ] || continue
    import_workflow "$wf"
  done
fi

echo ""
echo "✅ ${COUNT} workflows imported"
echo "   ⚠️  Credentials need to be reconnected manually in n8n UI"
