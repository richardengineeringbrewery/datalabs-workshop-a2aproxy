#!/usr/bin/env bash
# Deploys the proxy to Cloud Run. Requires gcloud to be authenticated.
# Usage: ELASTIC_A2A_URL=... ELASTIC_API_KEY=... [ELASTIC_AGENT_CARD_URL=...] ./deploy.sh
set -euo pipefail

: "${ELASTIC_A2A_URL:?Set ELASTIC_A2A_URL to the Elastic A2A JSON-RPC endpoint}"
: "${ELASTIC_API_KEY:?Set ELASTIC_API_KEY to the Elastic API key}"

SERVICE_NAME="${SERVICE_NAME:-a2aproxy}"
REGION="${REGION:-us-central1}"

ENV_VARS="ELASTIC_A2A_URL=${ELASTIC_A2A_URL},ELASTIC_API_KEY=${ELASTIC_API_KEY}"
if [[ -n "${ELASTIC_AGENT_CARD_URL:-}" ]]; then
  ENV_VARS="${ENV_VARS},ELASTIC_AGENT_CARD_URL=${ELASTIC_AGENT_CARD_URL}"
fi

gcloud run deploy "${SERVICE_NAME}" \
  --source . \
  --region "${REGION}" \
  --allow-unauthenticated \
  --set-env-vars "${ENV_VARS}"
