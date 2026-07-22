#!/usr/bin/env bash
# One-time setup: creates a GCP OAuth consent screen ("brand") and a Web
# application OAuth2 client, so Gemini Enterprise can authenticate directly
# against Google (authorization code flow) instead of this proxy.
#
# Run this once yourself and review the output — creating a brand is a
# one-time, effectively permanent action per GCP project, so it is kept out
# of deploy.sh. Paste the printed client_id/client_secret into Gemini
# Enterprise's agent connection settings; the secret may not be retrievable
# again afterwards.
#
# Requires: gcloud components install alpha
# Usage: ./setup-oauth.sh <redirect-uri> [support-email] [project-id]
set -euo pipefail

REDIRECT_URI="${1:?Usage: ./setup-oauth.sh <redirect-uri> [support-email] [project-id]}"
PROJECT_ID="${3:-$(gcloud config get-value project)}"
SUPPORT_EMAIL="${2:-$(gcloud config get-value account)}"

BRAND="$(gcloud alpha iap oauth-brands list --project="${PROJECT_ID}" --format="value(name)" | head -1)"
if [[ -z "${BRAND}" ]]; then
  gcloud alpha iap oauth-brands create \
    --application_title="A2A Proxy" \
    --support_email="${SUPPORT_EMAIL}" \
    --project="${PROJECT_ID}"
  BRAND="$(gcloud alpha iap oauth-brands list --project="${PROJECT_ID}" --format="value(name)" | head -1)"
fi

echo "Using brand: ${BRAND}"
echo "Creating OAuth client with redirect URI: ${REDIRECT_URI}"
echo "Copy the client_id and secret from the output below into Gemini Enterprise."
gcloud alpha iap oauth-clients create "${BRAND}" \
  --display_name="gemini-enterprise-a2a" \
  --redirect_uris="${REDIRECT_URI}" \
  --project="${PROJECT_ID}"
