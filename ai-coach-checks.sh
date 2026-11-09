#!/usr/bin/env bash
# AI coach -> Pub/Sub -> interpreter -> Redis -> WebSocket : verification commands
#
# Usage:
#   export PROJECT=adtgcp-ent-tst-ccs-tlcm-8143   # or DEV: adtgcp-ent-dev-ccs-tlcm-fe10
#   export LOCATION=global                         # or regional, e.g. us-central1 (must match the profile!)
#   export PROFILE_ID=<conversation-profile-id>
#   export SUGG_TOPIC=agent-assist-notification
#   ./ai-coach-checks.sh <step>
#
# Read-only steps : profiles | profile | generators | topic | readonly (= profile+generators+topic)
# Tap the topic   : tap-create | pull | watch | tap-delete
# Live test       : simulate | complete            (creates a REAL conversation -> real topics -> interpreter)
# Downstream      : logs | redis | ws               (logs runs; redis/ws print the interactive command)
# Changes config  : patch                          (dry-run diff; CONFIRM=yes to apply)

set -euo pipefail

: "${PROJECT:?set PROJECT}"
LOCATION="${LOCATION:-global}"
SUGG_TOPIC="${SUGG_TOPIC:-agent-assist-notification}"
TAP_SUB="${TAP_SUB:-ai-coach-tap-$(whoami)}"
STATE_DIR="${STATE_DIR:-./ai-coach-out}"
mkdir -p "$STATE_DIR"

# global vs regional endpoint -- mismatch here = "not found"/"No messages found"
if [[ "$LOCATION" == "global" ]]; then HOST="dialogflow.googleapis.com"; else HOST="${LOCATION}-dialogflow.googleapis.com"; fi
BASE="https://${HOST}/v2beta1/projects/${PROJECT}/locations/${LOCATION}"

api() { # api METHOD URL [json-body]
  local method="$1" url="$2" body="${3:-}"
  local args=(-sS -X "$method" "$url"
    -H "Authorization: Bearer $(gcloud auth print-access-token)"
    -H "x-goog-user-project: ${PROJECT}"
    -H "Content-Type: application/json; charset=utf-8")
  [[ -n "$body" ]] && args+=(-d "$body")
  curl "${args[@]}"
}

need_profile() { : "${PROFILE_ID:?set PROFILE_ID}"; PROFILE="projects/${PROJECT}/locations/${LOCATION}/conversationProfiles/${PROFILE_ID}"; }

# ---------------------------------------------------------------- read-only

step_profiles() {
  echo "== Conversation profiles in ${LOCATION}"
  api GET "${BASE}/conversationProfiles?pageSize=100" \
    | jq -r '.conversationProfiles[]? | "\(.name | split("/") | last)\t\(.displayName)"'
}

step_profile() {
  need_profile
  echo "== Profile ${PROFILE_ID} (raw saved to ${STATE_DIR}/profile.json)"
  api GET "${BASE}/conversationProfiles/${PROFILE_ID}" > "${STATE_DIR}/profile.json"
  jq '{
    displayName,
    suggestionTopic:          .humanAgentAssistantConfig.notificationConfig.topic,      # AI coach events go HERE
    suggestionMsgFormat:      .humanAgentAssistantConfig.notificationConfig.messageFormat,
    lifecycleTopic:           .notificationConfig.topic,                                 # CONVERSATION_STARTED/FINISHED
    newMessageTopic:          .newMessageEventNotificationConfig.topic,
    groupSuggestionResponses: .humanAgentAssistantConfig.humanAgentSuggestionConfig.groupSuggestionResponses,     # want true
    skipEmptyEventBased:      .humanAgentAssistantConfig.humanAgentSuggestionConfig.skipEmptyEventBasedSuggestion, # want true
    useUnredactedData:        .humanAgentAssistantConfig.humanAgentSuggestionConfig.useUnredactedConversationData, # DLP impact
    generators:               .humanAgentAssistantConfig.humanAgentSuggestionConfig.generators,
    features: [ .humanAgentAssistantConfig.humanAgentSuggestionConfig.featureConfigs[]?
                | {type: .suggestionFeature.type, eventBased: .enableEventBasedSuggestion} ]
  }' "${STATE_DIR}/profile.json"

  echo
  echo "-- sanity:"
  jq -r --arg t "$SUGG_TOPIC" '
    (.humanAgentAssistantConfig.notificationConfig.topic // "") as $s |
    (.notificationConfig.topic // "") as $l |
    if ($s|endswith("/"+$t)) then "OK   \($t) is the SUGGESTION topic"
    elif ($l|endswith("/"+$t)) then "WARN \($t) is the LIFECYCLE topic, not suggestions -> no coach events there"
    else "WARN \($t) not referenced as suggestion or lifecycle topic" end,
    (if .humanAgentAssistantConfig.humanAgentSuggestionConfig.groupSuggestionResponses == true
       then "OK   groupSuggestionResponses=true (payload inline in Pub/Sub)"
       else "WARN groupSuggestionResponses not true -> suggestionResults will be missing from Pub/Sub msg" end),
    (if .humanAgentAssistantConfig.humanAgentSuggestionConfig.skipEmptyEventBasedSuggestion == true
       then "OK   skipEmptyEventBasedSuggestion=true"
       else "INFO skipEmptyEventBasedSuggestion not set -> expect empty events per utterance" end)
  ' "${STATE_DIR}/profile.json"
}

step_generators() {
  echo "== Generators in ${LOCATION} (raw saved to ${STATE_DIR}/generators.json)"
  api GET "${BASE}/generators?pageSize=100" > "${STATE_DIR}/generators.json"
  jq '[.generators[]? | {
        id: (.name | split("/") | last),
        description,
        triggerEvent,
        isAiCoach: (.agentCoachingContext != null),
        instructions: ((.agentCoachingContext.instructions // []) | map(.displayName))
      }]' "${STATE_DIR}/generators.json"
  echo "-- cross-check: generator IDs above should appear in profile.generators (run 'profile')"
}

step_topic() {
  echo "== Topic ${SUGG_TOPIC}"
  gcloud pubsub topics describe "$SUGG_TOPIC" --project "$PROJECT" --format='value(name)'

  echo "-- subscriptions on topic (interpreter push sub should be here)"
  for s in $(gcloud pubsub topics list-subscriptions "$SUGG_TOPIC" --project "$PROJECT" --format='value(.)'); do
    gcloud pubsub subscriptions describe "$s" --format='table[box](name.basename(), pushConfig.pushEndpoint, ackDeadlineSeconds, deadLetterPolicy.deadLetterTopic.basename())'
  done

  echo "-- Dialogflow service agent must have roles/pubsub.publisher on the topic (or project)"
  local num; num=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
  local sa="service-${num}@gcp-sa-dialogflow.iam.gserviceaccount.com"
  echo "   expected SA: $sa"
  if gcloud pubsub topics get-iam-policy "$SUGG_TOPIC" --project "$PROJECT" --format=json | grep -q "$sa" \
     || gcloud projects get-iam-policy "$PROJECT" --format=json \
          --flatten='bindings[].members' --filter="bindings.members:$sa AND bindings.role:roles/pubsub.publisher" \
          | grep -q "$sa"; then
    echo "   OK   publisher binding found"
  else
    echo "   WARN no publisher binding found for $sa (check custom roles / org policy)"
  fi
}

# ---------------------------------------------------------------- tap the topic
# A separate pull subscription gets its own copy of every message,
# so it does NOT steal events from the interpreter's push subscription.

step_tap_create() {
  gcloud pubsub subscriptions create "$TAP_SUB" --project "$PROJECT" --topic "$SUGG_TOPIC" \
    --ack-deadline=60 --message-retention-duration=1h --expiration-period=1d
  echo "Tap created: $TAP_SUB (auto-expires after 1 day idle)"
}

decode_msgs() { # stdin: gcloud pull json
  jq -c '.[]' | while read -r m; do
    local ts; ts=$(jq -r '.message.publishTime' <<<"$m")
    local f="${STATE_DIR}/evt-$(date +%s%N).json"
    jq -r '.message.data' <<<"$m" | base64 -d > "$f"
    echo "---- $ts  attrs=$(jq -c '.message.attributes // {}' <<<"$m")  saved=$f"
    jq '{
      conversation: (.conversation | split("/") | last),
      participant:  (.participant  // "" | split("/") | last),
      resultKinds:  [ .suggestionResults[]? | keys[] ],
      coach: [ .suggestionResults[]?.generateSuggestionsResponse.generatorSuggestionAnswers[]?
               .generatorSuggestion.agentCoachingSuggestion // empty ]
    }' "$f" 2>/dev/null || cat "$f"
  done
}

step_pull() {
  gcloud pubsub subscriptions pull "$TAP_SUB" --project "$PROJECT" --auto-ack --limit=20 --format=json | decode_msgs
}

step_watch() {
  echo "Watching $TAP_SUB (Ctrl-C to stop)..."
  while true; do
    gcloud pubsub subscriptions pull "$TAP_SUB" --project "$PROJECT" --auto-ack --limit=20 --format=json | decode_msgs
    sleep 3
  done
}

step_tap_delete() {
  gcloud pubsub subscriptions delete "$TAP_SUB" --project "$PROJECT" --quiet
}

# ---------------------------------------------------------------- live test (no phone call needed)
# Creates a real conversation on the profile and feeds customer text via analyzeContent.
# Event-based suggestions fire exactly as on a call -> real topics -> interpreter -> Redis -> WS.
# The analyzeContent response ALSO shows suggestions inline, a quick check that the coach itself works.

step_simulate() {
  need_profile
  local conv cust agent
  conv=$(api POST "${BASE}/conversations" "{\"conversationProfile\":\"${PROFILE}\"}" | jq -r '.name')
  [[ "$conv" == "null" || -z "$conv" ]] && { echo "conversation create failed"; exit 1; }
  echo "$conv" > "${STATE_DIR}/last_conversation"
  echo "Conversation: $conv"

  cust=$(api POST "https://${HOST}/v2beta1/${conv}/participants" '{"role":"END_USER"}'    | jq -r '.name')
  agent=$(api POST "https://${HOST}/v2beta1/${conv}/participants" '{"role":"HUMAN_AGENT"}' | jq -r '.name')
  echo "Customer: $cust"; echo "Agent:    $agent"

  # Edit these lines to match the situations your AI coach instructions target
  local lines=(
    "Hi, I want to cancel my alarm monitoring service."
    "It is too expensive, I found a cheaper provider."
    "I have been a customer for six years."
  )
  for t in "${lines[@]}"; do
    echo; echo ">> customer: $t"
    api POST "https://${HOST}/v2beta1/${cust}:analyzeContent" \
      "$(jq -n --arg t "$t" '{textInput:{text:$t, languageCode:"en-US"}}')" \
      | tee "${STATE_DIR}/analyze-$(date +%s%N).json" \
      | jq '{ humanAgentResultKinds: [ .humanAgentSuggestionResults[]? | keys[] ],
              coach: [ .humanAgentSuggestionResults[]?.generateSuggestionsResponse.generatorSuggestionAnswers[]?
                       .generatorSuggestion.agentCoachingSuggestion // empty ],
              error: .error }'
    sleep 2
    api POST "https://${HOST}/v2beta1/${agent}:analyzeContent" \
      '{"textInput":{"text":"I understand, let me see what I can do for you.","languageCode":"en-US"}}' > /dev/null
  done
  echo; echo "Now run: $0 pull   (tap)   and   $0 logs   (interpreter)"
}

step_complete() { # fires CONVERSATION_FINISHED -> also exercises your summarization path
  local conv; conv=$(cat "${STATE_DIR}/last_conversation")
  api POST "https://${HOST}/v2beta1/${conv}:complete" '{}' | jq '{name, lifecycleState}'
}

# ---------------------------------------------------------------- downstream

step_logs() {
  local since="${SINCE:-30m}"
  echo "== adt-pubsub-interpreter logs (last $since)"
  gcloud logging read \
    'resource.type="cloud_run_revision" AND resource.labels.service_name="adt-pubsub-interpreter"' \
    --project "$PROJECT" --freshness="$since" --limit=100 --order=asc \
    --format='value(timestamp, severity, textPayload, jsonPayload.message)' \
    | grep -iE "${GREP:-suggest|coach|generat|error|exception}" || echo "(no matching lines)"

  echo
  echo "== Push subscription errors (if any) -- Pub/Sub delivery to interpreter"
  gcloud logging read \
    'resource.type="pubsub_subscription" AND severity>=WARNING' \
    --project "$PROJECT" --freshness="$since" --limit=20 \
    --format='value(timestamp, resource.labels.subscription_id, jsonPayload.message, textPayload)' || true

  echo
  echo "== Connector side (GKE) -- run against the right cluster context:"
  echo "kubectl logs deploy/adt-ui-connectorv2 -n \${NS:-default} --since=$since | grep -iE 'coach|suggest'"
}

step_redis() {
  cat <<'EOF'
# Throwaway redis-cli pod in the cluster (Memorystore is VPC-only):
kubectl run redis-cli-$USER --rm -it --restart=Never --image=redis:7 -n ${NS:-default} -- \
  redis-cli -h <MEMORYSTORE_IP> -p 6379

# inside redis-cli:
PSUBSCRIBE *                              # watch every channel publish live while you run 'simulate'
# (new terminal / after Ctrl-C)
SCAN 0 MATCH *<CONVERSATION_ID>* COUNT 1000   # keys written for the test conversation
TYPE <key>
HGETALL <meta/coach hash key>
LRANGE <turns/coach list key> 0 -1
TTL <key>                                  # -1 = no TTL (the known gap)
EOF
}

step_ws() {
  cat <<'EOF'
# Plain Google ID token in ?token= (current TST mode)
TOKEN=$(gcloud auth print-identity-token)
websocat -v "wss://qa.agentassist.adt.com/<ws-path>?token=${TOKEN}&conversationId=<CONVERSATION_ID>"
# install: cargo install websocat   |  or: npx wscat -c "<same url>"
# expect 101 Switching Protocols, then transcript frames + the new ai_coach frame after 'simulate'
EOF
}

# ---------------------------------------------------------------- config change (guarded)

step_patch() {
  need_profile
  api GET "${BASE}/conversationProfiles/${PROFILE_ID}" > "${STATE_DIR}/profile.backup.$(date +%s).json"
  local cur; cur=$(ls -t "${STATE_DIR}"/profile.backup.*.json | head -1)

  jq '.humanAgentAssistantConfig
      | .humanAgentSuggestionConfig.groupSuggestionResponses = true
      | .humanAgentSuggestionConfig.skipEmptyEventBasedSuggestion = true' "$cur" > "${STATE_DIR}/haac.new.json"

  echo "== Diff (humanAgentAssistantConfig only). Backup: $cur"
  diff <(jq -S '.humanAgentAssistantConfig' "$cur") <(jq -S . "${STATE_DIR}/haac.new.json") || true

  if [[ "${CONFIRM:-}" != "yes" ]]; then
    echo; echo "Dry run only. Re-run with CONFIRM=yes to apply."; return
  fi
  # whole humanAgentAssistantConfig sent back (from GET) -> no risk of nested-mask surprises
  api PATCH "${BASE}/conversationProfiles/${PROFILE_ID}?updateMask=humanAgentAssistantConfig" \
    "$(jq '{humanAgentAssistantConfig: .}' "${STATE_DIR}/haac.new.json")" \
    | jq '{name, updateTime,
           group: .humanAgentAssistantConfig.humanAgentSuggestionConfig.groupSuggestionResponses,
           skipEmpty: .humanAgentAssistantConfig.humanAgentSuggestionConfig.skipEmptyEventBasedSuggestion}'
}

# ---------------------------------------------------------------- dispatch
case "${1:-}" in
  profiles)   step_profiles ;;
  profile)    step_profile ;;
  generators) step_generators ;;
  topic)      step_topic ;;
  readonly)   step_profile; echo; step_generators; echo; step_topic ;;
  tap-create) step_tap_create ;;
  pull)       step_pull ;;
  watch)      step_watch ;;
  tap-delete) step_tap_delete ;;
  simulate)   step_simulate ;;
  complete)   step_complete ;;
  logs)       step_logs ;;
  redis)      step_redis ;;
  ws)         step_ws ;;
  patch)      step_patch ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
