# ui-connector — GKE Deployment Runbook

Pipeline: **source code → Cloud Build (builds image) → Artifact Registry → GKE pulls it**

- Project: `adtgcp-ent-dev-ccs-tlcm-fe10`
- Cluster: `gcldccsinsght01` (us-central1, private — kubectl runs via Cloud Build)
- Workload: `adt-ui-connectorv2-1`
- Host: `dev.agentassist.adt.com` (ILB `100.73.16.94`)
- Redis: `100.72.86.38:6379`

---

## Step 0 — Repo layout

All five files in one folder (repo root):

```
ui-connector/
├── main.py
├── requirements.txt
├── Dockerfile
├── deployment.yaml
└── cloudbuild.yaml
```

---

## Step 1 — Set project (once per shell)

```bash
gcloud config set project adtgcp-ent-dev-ccs-tlcm-fe10
```

---

## Step 2 — Create the Artifact Registry repo (one-time)

```bash
gcloud artifacts repositories create ui-connector \
  --repository-format=docker \
  --location=us-central1
```

> "Repository already exists" → fine, move on.

---

## Step 3 — Grant Cloud Build access to GKE (one-time)

```bash
PROJECT_NUMBER=$(gcloud projects describe adtgcp-ent-dev-ccs-tlcm-fe10 --format='value(projectNumber)')

gcloud projects add-iam-policy-binding adtgcp-ent-dev-ccs-tlcm-fe10 \
  --member="serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com" \
  --role="roles/container.developer"
```

---

## Step 4 — Check the existing Service selector (one-time, CRITICAL)

The existing NEG-annotated Service must select the pods this Deployment creates.
kubectl runs via a throwaway Cloud Build:

```bash
gcloud builds submit --no-source --config=/dev/stdin <<'EOF'
steps:
  - name: gcr.io/cloud-builders/kubectl
    args: ["get", "svc", "-o", "custom-columns=NAME:.metadata.name,SELECTOR:.spec.selector"]
    env:
      - CLOUDSDK_COMPUTE_REGION=us-central1
      - CLOUDSDK_CONTAINER_CLUSTER=gcldccsinsght01
options:
  logging: CLOUD_LOGGING_ONLY
EOF
```

Find the ui-connector Service in the output.

- Selector is `app: adt-ui-connectorv2-1` → nothing to do.
- Selector is anything else → edit `deployment.yaml` so **all three** label spots
  match it: `metadata.labels`, `spec.selector.matchLabels`,
  `template.metadata.labels`.

> If labels don't match, the failure is silent: the Service stops selecting
> any pods and the ILB backend drains to zero.

---

## Step 5 — Deploy

```bash
cd ui-connector
gcloud builds submit --config cloudbuild.yaml .
```

Log stream: build → push → apply → `rollout status`.
Success ends with: `deployment "adt-ui-connectorv2-1" successfully rolled out`.

**This is the only step for every future deploy.**

---

## Step 6 — Verify

From the VDI / anywhere that reaches the ILB:

```bash
curl https://dev.agentassist.adt.com/
```

Check three fields in the JSON:

| Field | Expected | Proves |
|---|---|---|
| `auth_enabled` | `false` | AUTH_ENABLED manifest patch took effect |
| `server_id` | `adt-ui-connectorv2-1-<hash>-<hash>` | POD_NAME downward API resolution working |
| `redis` | `connected` | Pod reaches `100.72.86.38` |

---

## Step 7 — WebSocket smoke test (Postman)

New → WebSocket request. With `AUTH_ENABLED=false`, no token needed:

```
wss://dev.agentassist.adt.com/ws?conversation_id=conv-test1234
```

Expected: a `HISTORY_BATCH` frame arrives, connection stays open.

> Handshake hangs or drops at the edge → that's the pending F5 network ticket
> (WebSocket upgrade + idle timeout), not the deployment. The Cloud Run
> endpoint remains the workaround test path until the ticket is resolved.

---

## Step 8 — End-to-end turn (optional but conclusive)

Keep Postman connected. From a VPC-reachable box:

```bash
# 1. Read the routing key the join wrote — value is the pod name
redis-cli -h 100.72.86.38 GET conv-test1234

# 2. Publish to that pod's channel: {server_id}:{conversation_id}
redis-cli -h 100.72.86.38 PUBLISH '<pod-name-from-step-1>:conv-test1234' '{"type":"test","text":"hello"}'
```

JSON appears in Postman → auth, join, routing key, and pub/sub forwarding all work.

---

## Rollback

```bash
gcloud builds submit --no-source --config=/dev/stdin <<'EOF'
steps:
  - name: gcr.io/cloud-builders/kubectl
    args: ["rollout", "undo", "deployment/adt-ui-connectorv2-1"]
    env:
      - CLOUDSDK_COMPUTE_REGION=us-central1
      - CLOUDSDK_CONTAINER_CLUSTER=gcldccsinsght01
options:
  logging: CLOUD_LOGGING_ONLY
EOF
```

Every image is tagged `manual-<build-id>` (immutable), so redeploying any
previous tag is also always possible.

---

## Known failure points (in order of probability)

1. **Step 5 dies at the deploy step with a cluster connection error** —
   private cluster: Cloud Build's IP may need to be in master authorized
   networks. Capture the exact error before changing anything.
2. **Step 6 times out** — F5/ILB path (known issue, network ticket pending).
3. Steps 2–3 permission errors — self-explanatory IAM messages; fix and re-run.

---

## Later: turning auth on

1. Salesforce team sends a Google-signed identity token as `access_token`
   query param.
2. Flip `AUTH_ENABLED: "true"` in `deployment.yaml`, redeploy (Step 5).
3. To pin audience: uncomment `WS_TOKEN_AUDIENCE` in `deployment.yaml`.
   ⚠ Once set, plain `gcloud auth print-identity-token` fails audience check —
   test with `gcloud auth print-identity-token --audiences=<value>`.
4. Include query-string scrubbing of `access_token` from F5/ILB access logs
   in the network ticket.
