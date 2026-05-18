#!/usr/bin/env bash
#
# Lists fillable-PDF templates stored in the project's Supabase project:
#   1. Rows in public.pdf_templates (name, field count, owner)
#   2. Objects in the pdf-templates Storage bucket (filename, size, owner)
#
# Usage:
#   SUPABASE_PAT=sbp_your_personal_access_token ./scripts/list-templates.sh
#
# Get a PAT at: https://supabase.com/dashboard/account/tokens
# Treat it like a password — anyone with it can act on your Supabase account.

set -euo pipefail

PROJECT_REF="lssmrwsirvyipqzlcqid"
API="https://api.supabase.com/v1/projects/${PROJECT_REF}/database/query"

if [ -z "${SUPABASE_PAT:-}" ]; then
  echo "Error: SUPABASE_PAT environment variable is not set."
  echo ""
  echo "Get a personal access token at:"
  echo "  https://supabase.com/dashboard/account/tokens"
  echo ""
  echo "Then run:"
  echo "  SUPABASE_PAT=sbp_xxxx ./scripts/list-templates.sh"
  exit 1
fi

query() {
  curl -sS -X POST "${API}" \
    -H "Authorization: Bearer ${SUPABASE_PAT}" \
    -H "Content-Type: application/json" \
    -d "$1"
}

echo "═══════════════════════════════════════════════════════════════"
echo " Templates in public.pdf_templates"
echo "═══════════════════════════════════════════════════════════════"
query '{"query": "select id, user_id, name, jsonb_array_length(field_names) as field_count, storage_path, created_at from public.pdf_templates order by created_at desc;"}' \
  | python3 -c "
import sys, json
rows = json.load(sys.stdin)
if not rows:
    print('  (no templates yet — upload one from the iOS app first)')
else:
    for r in rows:
        print()
        print(f\"  {r['name']}\")
        print(f\"    id          {r['id']}\")
        print(f\"    user        {r['user_id']}\")
        print(f\"    fields      {r['field_count']}\")
        print(f\"    storage     {r['storage_path']}\")
        print(f\"    created     {r['created_at']}\")
"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " Files in pdf-templates Storage bucket"
echo "═══════════════════════════════════════════════════════════════"
query '{"query": "select name, owner, created_at, (metadata->>'\''size'\'')::int as size_bytes from storage.objects where bucket_id = '\''pdf-templates'\'' order by created_at desc;"}' \
  | python3 -c "
import sys, json
rows = json.load(sys.stdin)
if not rows:
    print('  (bucket is empty)')
else:
    for r in rows:
        size = r.get('size_bytes') or 0
        kb = size / 1024
        print()
        print(f\"  {r['name']}\")
        print(f\"    owner       {r.get('owner','?')}\")
        print(f\"    size        {kb:.1f} KB\")
        print(f\"    created     {r['created_at']}\")
"

echo ""
echo "Done. To download a specific template's PDF locally:"
echo "  SUPABASE_PAT=… ./scripts/download-template.sh <storage_path>"
echo "(That script isn't created yet — ping the codebase if you want it.)"
