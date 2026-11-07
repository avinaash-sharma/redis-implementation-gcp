#!/usr/bin/env bash
# Runs each test turn through the DLP API on its own, as Dialogflow does,
# and checks whether it was redacted as expected.
#   ./dlp-check.sh inline     # tests patch-request-card-only.json without changing the live template
#   ./dlp-check.sh template   # tests the live template
set -uo pipefail
MODE="${1:-inline}"
PROJECT_ID="adtgcp-ent-tst-ccs-tlcm-8143"
LOCATION="us-central1"
TEMPLATE_NAME="projects/$PROJECT_ID/locations/$LOCATION/inspectTemplates/adt-industry-standard-pci-template"
CONFIG_FILE="patch-request-card-only.json"
TESTS="dlp-test-turns.tsv"
TOKEN="$(gcloud auth print-access-token)"
URL="https://dlp.googleapis.com/v2/projects/$PROJECT_ID/locations/$LOCATION/content:deidentify"
DEID='{"infoTypeTransformations":{"transformations":[{"primitiveTransformation":{"characterMaskConfig":{"maskingCharacter":"*","charactersToIgnore":[{"commonCharactersToIgnore":"WHITESPACE"}]}}}]}}'

pass=0; fail=0
while IFS=$'\t' read -r expect text; do
  [ -z "$text" ] && continue
  if [ "$MODE" = "template" ]; then
    body="$(jq -n --arg t "$TEMPLATE_NAME" --arg v "$text" --argjson d "$DEID" \
      '{inspectTemplateName:$t, deidentifyConfig:$d, item:{value:$v}}')"
  else
    body="$(jq -n --slurpfile c "$CONFIG_FILE" --arg v "$text" --argjson d "$DEID" \
      '{inspectConfig:$c[0].inspectTemplate.inspectConfig, deidentifyConfig:$d, item:{value:$v}}')"
  fi
  resp="$(curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $PROJECT_ID" \
    -H "Content-Type: application/json" -d "$body" "$URL")"
  err="$(jq -r '.error.message // empty' <<<"$resp")"
  if [ -n "$err" ]; then echo "ERROR  $text  ->  $err"; fail=$((fail+1)); continue; fi
  out="$(jq -r '.item.value' <<<"$resp")"
  got=$([ "$out" != "$text" ] && echo REDACT || echo KEEP)
  if [ "$got" = "$expect" ]; then status="PASS"; pass=$((pass+1)); else status="FAIL"; fail=$((fail+1)); fi
  printf '%s  %-6s  %-55s ->  %s\n' "$status" "$expect" "$text" "$out"
done < "$TESTS"
echo "---"; echo "pass=$pass fail=$fail"
