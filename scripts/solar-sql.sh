#!/usr/bin/env bash
#
# Read-only SQL against the Prince Solar production database.
#
# WHY THIS EXISTS. The `supabase` CLI keeps ONE login per machine, and this
# machine's default login is the newer Supabase account (created for a third
# project). The solar project lives on the OLDER account, so a bare
# `supabase db query --linked` returns 403 -- linked, but not authorized.
#
# SUPABASE_ACCESS_TOKEN overrides the stored login for a single invocation, so
# this reaches the solar project without disturbing the default login or
# forcing a logout/login dance between accounts.
#
# SETUP (once). Generate a personal access token while signed into the OWNING
# account at https://supabase.com/dashboard/account/tokens, then add it to
# .env (already gitignored, alongside the SunSynk credentials):
#
#     SUPABASE_SOLAR_TOKEN=sbp_...
#
# USAGE
#     scripts/solar-sql.sh "select now();"
#     scripts/solar-sql.sh -f scripts/sql/grid-presence.sql
#     FMT=json scripts/solar-sql.sh "select ..."     # table (default) | json | csv
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPECTED_REF="pmakzojwhouamawgszrc"

# Token: environment first, then .env. Read by grep rather than sourcing, so a
# stray line in .env cannot execute anything here.
TOKEN="${SUPABASE_ACCESS_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f "$ROOT/.env" ]; then
  TOKEN=$(grep -E '^[[:space:]]*SUPABASE_SOLAR_TOKEN[[:space:]]*=' "$ROOT/.env" \
          | tail -1 | cut -d= -f2- | tr -d "\"' " || true)
fi
if [ -z "$TOKEN" ]; then
  echo "No token. Add SUPABASE_SOLAR_TOKEN=sbp_... to .env (see header)." >&2
  exit 1
fi

# The linked ref decides which database --linked talks to. If the repo is ever
# relinked, fail loudly rather than querying some other project by accident.
REF_FILE="$ROOT/supabase/.temp/project-ref"
if [ -f "$REF_FILE" ]; then
  REF="$(tr -d '[:space:]' < "$REF_FILE")"
  if [ "$REF" != "$EXPECTED_REF" ]; then
    echo "Linked project is $REF, expected $EXPECTED_REF (the solar project)." >&2
    echo "Re-link with: supabase link --project-ref $EXPECTED_REF" >&2
    exit 1
  fi
fi

# Reads only. This script is meant to be safe to run unattended; anything that
# writes should be a migration, reviewed and pushed like every other change.
SQL_TEXT="$*"
if [ "${1:-}" = "-f" ] && [ -n "${2:-}" ]; then SQL_TEXT="$(cat "$2")"; fi
if printf '%s' "$SQL_TEXT" | grep -qiE '\b(insert|update|delete|drop|truncate|alter|create|grant|revoke)\b'; then
  echo "Refusing: this wrapper is for reads. Write changes as a migration." >&2
  exit 1
fi

cd "$ROOT"
SUPABASE_ACCESS_TOKEN="$TOKEN" exec supabase db query --linked -o "${FMT:-table}" "$@"
