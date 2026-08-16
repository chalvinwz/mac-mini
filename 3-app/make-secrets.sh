#!/usr/bin/env bash
# Render 05-secrets.yaml, beside this script, from the two app repos' .env files.
# Prints key NAMES only, never values. The output is gitignored.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# HERE is <parent>/mac-mini/3-app; the two app repos are siblings of mac-mini.
SRC="$(cd "$HERE/../.." && pwd)"
BACK="${BACKEND_ENV:-$SRC/planpal-backend-learner7-ch4/.env}"
FRONT="${FRONTEND_ENV:-$SRC/planpal-frontend-learner7-ch4/.env}"
OUT_DIRS="$HERE"

for f in "$BACK" "$FRONT"; do
  [ -f "$f" ] || { echo "missing env file: $f" >&2; exit 1; }
done

# Read KEY=VALUE without sourcing the file — `source` would execute anything in it,
# and a value containing $(...) or backticks is a real hazard in a credentials file.
US=$(printf '\037')
PARSED="$(mktemp)"; TMP="$(mktemp)"
chmod 600 "$PARSED" "$TMP"
trap 'rm -f "$PARSED" "$TMP"' EXIT

parse() {
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$(printf '\r')}"
    case "$line" in ''|\#*) continue ;; esac
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in \#*) continue ;; export\ *) line="${line#export }" ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    case "$key" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    if [ ${#val} -ge 2 ]; then
      case "$val" in
        \"*\") val="${val#\"}"; val="${val%\"}" ;;
        \'*\') val="${val#\'}"; val="${val%\'}" ;;
      esac
    fi
    printf '%s%s%s\n' "$key" "$US" "$val" >> "$PARSED"
  done < "$1"
}
parse "$BACK"
parse "$FRONT"

lookup() {
  awk -v k="$1" -v us="$US" 'BEGIN{FS=us} $1==k {v=substr($0, index($0,us)+1)} END{printf "%s", v}' "$PARSED"
}

missing=""; placeholders=""
emit() {
  local key="$1" req="$2" val
  val="$(lookup "$key")"
  if [ -z "$val" ]; then
    [ "$req" = required ] && missing="$missing $key"
    return 0
  fi
  # `your-google-client-id` shipped to a live cluster once because it matched none of
  # these and is shaped exactly like a real client ID (48 chars, correct suffix).
  case "$val" in
    *ChangeMe*|*changeme*|*CHANGEME*|placeholder*|your-*|*-here|xxx*|TODO*)
      placeholders="$placeholders $key" ;;
  esac
  printf '  %s: %s\n' "$key" "'$(printf '%s' "$val" | sed "s/'/''/g")'"
}

hdr() { printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: planpal\ntype: Opaque\nstringData:\n' "$1"; }

{
  hdr planpal-db
  emit POSTGRES_USER required; emit POSTGRES_PASSWORD required; emit POSTGRES_DB required

  printf -- '---\n'; hdr planpal-env
  for k in SECRET_DATABASE_URL SECRET_REDIS_URL SECRET_JWT_SECRET \
           SECRET_GOOGLE_CLIENT_ID SECRET_GOOGLE_CLIENT_SECRET \
           SECRET_SMTP_USERNAME SECRET_SMTP_PASSWORD \
           SECRET_FCM_SERVICE_ACCOUNT_JSON \
           SECRET_SLACK_SIGNING_SECRET SECRET_SLACK_BOT_TOKEN \
           APP__DATABASE__URL; do emit "$k" required; done
  for k in SECRET_AI_API_KEY APP__EMAIL__PROVIDER APP__SMTP__HOST APP__SMTP__PORT \
           APP__SMTP__FROM APP__AI__PROVIDER APP__AI__MODEL_ID APP__AI__API_BASE_URL; do
    emit "$k" optional; done

  printf -- '---\n'; hdr planpal-seed-admin
  emit SEED_ADMIN_EMAIL required; emit SEED_ADMIN_PASSWORD required; emit SEED_ADMIN_NAME optional

  printf -- '---\n'; hdr planpal-web-env
  emit SECRET_SOURCE optional; emit SECRET_PATH optional
  for k in SECRET_FIREBASE_API_KEY SECRET_FIREBASE_AUTH_DOMAIN SECRET_FIREBASE_PROJECT_ID \
           SECRET_FIREBASE_STORAGE_BUCKET SECRET_FIREBASE_MESSAGING_SENDER_ID \
           SECRET_FIREBASE_APP_ID SECRET_FIREBASE_MEASUREMENT_ID SECRET_FIREBASE_VAPID_KEY; do
    emit "$k" required; done
} > "$TMP"

if [ -n "$missing" ]; then
  echo "missing required keys:" >&2
  for k in $missing; do echo "  $k" >&2; done
  exit 1
fi

for d in $OUT_DIRS; do
  [ -d "$d" ] || continue
  install -m 600 "$TMP" "$d/05-secrets.yaml"
  echo "wrote ${d#$SRC/}/05-secrets.yaml (mode 600, gitignored)"
done
[ -n "$placeholders" ] && { echo; echo "still placeholders:"; for k in $placeholders; do echo "  $k"; done; }
echo
echo "apply with:  kubectl apply -f 3-app/"
