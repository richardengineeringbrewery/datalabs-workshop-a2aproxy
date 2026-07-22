#!/usr/bin/env bash
# Deploys the proxy to Cloud Run. Requires gcloud to be authenticated.
#
# Usage: ./deploy.sh   (fill in ELASTIC_API_KEY below first)

# --- Fill this in ---
# Elastic API key (Kibana's "encoded" id:key value). This is a secret and this
# file is tracked in git, so committing it will put the key in git history
# (and push it to origin).
ELASTIC_API_KEY="CHANGE_ME_ELASTIC_API_KEY"
# ---------------------

# The Elastic A2A URL is read automatically from agent-card.json (fetched from
# <a2a-url>/.well-known/agent-card.json) placed next to this script — no need
# to set it here.
#
# First run only, to also create (or reuse) the Google OAuth consent screen
# ("brand") and Web application OAuth client that Gemini Enterprise
# authenticates against, additionally pass the redirect URI shown on Gemini
# Enterprise's connection-setup screen:
#
#   REDIRECT_URI=<uri-from-gemini-enterprise> ./deploy.sh
#
# The client_id/secret are printed for you to paste into Gemini Enterprise —
# omit REDIRECT_URI on later redeploys, the existing client is reused.
# Requires: gcloud components install alpha   (only needed for OAuth setup)
set -euo pipefail

PYTHON_BIN=""
for candidate in python3 python; do
  if command -v "${candidate}" >/dev/null 2>&1 && "${candidate}" -c "" >/dev/null 2>&1; then
    PYTHON_BIN="${candidate}"
    break
  fi
done
if [[ -z "${PYTHON_BIN}" ]]; then
  echo "No working python3/python interpreter found on PATH." >&2
  exit 1
fi

AGENT_CARD_FILE="${AGENT_CARD_FILE:-agent-card.json}"
if [[ ! -f "${AGENT_CARD_FILE}" ]]; then
  echo "Missing ${AGENT_CARD_FILE}. Fetch it from <elastic-a2a-url>/.well-known/agent-card.json and save it here (see agent-card.example.json)." >&2
  exit 1
fi

# Elastic's raw agent card export uses triple-quoted strings for multi-line
# description fields, which isn't valid JSON — repair before parsing.
ELASTIC_A2A_URL="$("${PYTHON_BIN}" - "${AGENT_CARD_FILE}" <<'PYEOF'
import json, re, sys

raw = open(sys.argv[1], encoding="utf-8").read()
fixed = re.sub(r'"""(.*?)"""', lambda m: json.dumps(m.group(1)), raw, flags=re.DOTALL)
print(json.loads(fixed)["url"])
PYEOF
)"
ELASTIC_AGENT_CARD_URL="${ELASTIC_A2A_URL}/.well-known/agent-card.json"

if [[ "${ELASTIC_API_KEY}" == "CHANGE_ME_ELASTIC_API_KEY" ]]; then
  echo "Set ELASTIC_API_KEY at the top of deploy.sh." >&2
  exit 1
fi

SERVICE_NAME="${SERVICE_NAME:-a2aproxy}"
REGION="${REGION:-us-central1}"
PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project)}"
OAUTH_CLIENT_DISPLAY_NAME="${OAUTH_CLIENT_DISPLAY_NAME:-gemini-enterprise-a2a}"

if [[ -n "${REDIRECT_URI:-}" ]]; then
  SUPPORT_EMAIL="${SUPPORT_EMAIL:-$(gcloud config get-value account)}"

  BRAND="$(gcloud alpha iap oauth-brands list --project="${PROJECT_ID}" --format="value(name)" | head -1)"
  if [[ -z "${BRAND}" ]]; then
    gcloud alpha iap oauth-brands create \
      --application_title="A2A Proxy" \
      --support_email="${SUPPORT_EMAIL}" \
      --project="${PROJECT_ID}"
    BRAND="$(gcloud alpha iap oauth-brands list --project="${PROJECT_ID}" --format="value(name)" | head -1)"
  fi

  EXISTING_CLIENT="$(gcloud alpha iap oauth-clients list "${BRAND}" \
    --filter="displayName=${OAUTH_CLIENT_DISPLAY_NAME}" \
    --format="value(name)" | head -1)"

  if [[ -z "${EXISTING_CLIENT}" ]]; then
    echo "Creating OAuth client with redirect URI: ${REDIRECT_URI}"
    echo "Copy the client_id and secret from the output below into Gemini Enterprise — this is the only time the secret is shown."
    gcloud alpha iap oauth-clients create "${BRAND}" \
      --display_name="${OAUTH_CLIENT_DISPLAY_NAME}" \
      --redirect_uris="${REDIRECT_URI}"
  else
    echo "OAuth client already exists: ${EXISTING_CLIENT} (skipping creation, not re-printing secret)"
  fi
fi

ENV_VARS="ELASTIC_A2A_URL=${ELASTIC_A2A_URL},ELASTIC_API_KEY=${ELASTIC_API_KEY},ELASTIC_AGENT_CARD_URL=${ELASTIC_AGENT_CARD_URL}"

gcloud run deploy "${SERVICE_NAME}" \
  --source . \
  --region "${REGION}" \
  --project "${PROJECT_ID}" \
  --allow-unauthenticated \
  --set-env-vars "${ENV_VARS}"

SERVICE_URL="$(gcloud run services describe "${SERVICE_NAME}" \
  --region "${REGION}" \
  --project "${PROJECT_ID}" \
  --format="value(status.url)")"

echo "Agent card URL for Gemini Enterprise: ${SERVICE_URL}/.well-known/agent-card.json"
