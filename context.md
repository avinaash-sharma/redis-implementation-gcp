# GEMINI.md — ISSUE: Salesforce Cannot Connect to Our WebSocket (Header Limitation)

You are assisting with ONE specific issue. Read the problem statement and the change we already made before suggesting anything. Do not redesign the architecture — work within the approach described here.

---

## 1. PROBLEM STATEMENT (the single focus of this session)

**Salesforce (LWC in the agent's browser) is unable to connect to our WebSocket service because the browser cannot attach an `Authorization` header to a WebSocket connection.**

Details:

- Our WebSocket service `adt-ui-connectorv2` (FastAPI/uvicorn) was originally protected in a way that required `Authorization: Bearer <GCP identity token>` on the request:
  - On **Cloud Run**, this is enforced by Cloud Run IAM itself (org policy blocks unauthenticated invocation — this cannot be turned off).
  - Any request without the header gets **HTTP 403 before the WebSocket upgrade even happens**.
- The browser `WebSocket` API (`new WebSocket(url)`) **does not allow setting custom headers**. There is no way for an LWC — or any browser client — to send `Authorization: Bearer ...` on a WebSocket handshake. This is a platform limitation, not a bug in our code.
- Result: **Postman works** (it can set the header), **Salesforce fails with 403 forever** on the Cloud Run URL.

So the problem splits into two layers:
1. **Transport-layer gate (Cloud Run IAM):** unsolvable for browsers → this is why the browser-facing endpoint is the **GKE deployment** (`wss://agentassist.adt.com/ws` behind an internal ALB), which has NO IAM gate in front of it.
2. **App-layer auth:** since the browser can't send a header, the app needs another way to receive the token → this is the change we made (Section 2).

---

## 2. THE CHANGE WE MADE — Token via Query Parameter (focus on this)

Because headers are impossible from the browser, we moved authentication **into the URL as a `?token=` query parameter**, validated inside the FastAPI app itself.

### What was changed

**Client side (connection URL):**

```
Before (impossible from browser):
  wss://<host>/ws?conversationId=...        + header: Authorization: Bearer eyJ...

After (works from browser):
  wss://agentassist.adt.com/ws?conversationId=...&token=eyJ...
```

**Server side (`adt-ui-connectorv2`):** a `verify_gcp_token` function was added to the WebSocket endpoint. On connection:

1. Extract `token` from the query parameters of the WebSocket handshake request.
2. Validate it as a **Google identity token** using `google.oauth2.id_token.verify_oauth2_token` (Google's public keys, signature + expiry checked).
3. If env var `WS_TOKEN_AUDIENCE` is set on the service, the token's `aud` claim must match it exactly.
4. Invalid/missing/expired token → the app **accepts then closes the socket with code 1008** (policy violation). Valid token → connection proceeds to join/HISTORY_BATCH flow.

### Strict token requirements (frequent failure causes)

- Must be an **identity token** — a JWT starting with `eyJ...`. An OAuth **access token** (`ya29...`) will ALWAYS be rejected by `verify_oauth2_token`.
- Identity tokens **expire after 1 hour**. A stale token in a saved URL is the #1 cause of 1008 closes during testing.
- `aud` claim must match `WS_TOKEN_AUDIENCE` (if set). Token minted with a different `--audiences` value → 1008.

### How each client now authenticates

| Client | Endpoint | How it gets past auth |
|---|---|---|
| Postman (dev testing) | Cloud Run URL | BOTH: `Authorization: Bearer <token>` header (for Cloud Run IAM) AND same token in `?token=` (for app check). Mint with `gcloud auth print-identity-token`. **Confirmed working** — full pipeline validated. |
| Salesforce LWC (production path) | GKE: `wss://agentassist.adt.com/ws` | ONLY `?token=` — no header needed because there is no IAM gate on the GKE path. Token is minted server-side in Salesforce (below). |

### Salesforce-side token minting (in progress — the browser can't mint a Google token either)

The LWC can't create a Google identity token itself, so Apex does it via a service-account JWT bearer flow:

1. GCP service account: `sf-ws-client@adtgcp-ent-dev-ccs-tlcm-fe10.iam.gserviceaccount.com`; its private key is imported into Salesforce **Setup → Certificates** as `GCP_SA_Cert`.
2. Apex class `GcpTokenService.getIdToken()` builds an `Auth.JWT` (iss/sub = SA email, aud = `https://oauth2.googleapis.com/token`, additional claim `target_audience` = our WS audience), signs it via `Auth.JWS` with `GCP_SA_Cert`, and exchanges it with `Auth.JWTBearerTokenExchange` — Google returns an `id_token`.
3. LWC calls the `@AuraEnabled` Apex method → receives `id_token` → opens `wss://agentassist.adt.com/ws?...&token=<id_token>`.
4. **The Apex `AUDIENCE` constant must be byte-identical to `WS_TOKEN_AUDIENCE` on the connector.** Mismatch = 1008.

---

## 3. Current status against this issue

WORKING:
- Postman → Cloud Run with header + query param: connects, join → HISTORY_BATCH flow validated. Proves `verify_gcp_token` and the pipeline are correct.

NOT WORKING / REMAINING:
- Salesforce LWC → GKE `wss://` endpoint end to end. Dependencies: (a) GKE ILB reachable with TLS (pre-shared regional cert), (b) Apex token flow completed and tested, (c) audience alignment.
- The Apex JWT bearer flow is written but not yet verified end to end.

## 4. Diagnostic table (interpret symptoms in terms of THIS design)

| Symptom | Meaning | Action |
|---|---|---|
| HTTP 403 before upgrade | You are hitting **Cloud Run** (IAM gate) or wrong Host on the GKE ILB — NOT an app-token problem | Confirm target is the GKE ILB `100.73.16.94` with `Host: agentassist.adt.com`; wait ~5 min after Ingress host changes |
| Connects, then close 1008 | App rejected the `?token=` value | Fresh token (<1h), identity token not access token, `aud` = `WS_TOKEN_AUDIENCE` |
| Drops at ~30s | LB timeout, unrelated to auth | BackendConfig `timeoutSec: 3600` must be attached |
| Apex token exchange fails | JWT bearer flow misconfigured | Check `GCP_SA_Cert` matches SA key; aud = token URL; `target_audience` claim present |

## 5. Environment reference (secondary — only what's needed)

- Project `adtgcp-ent-dev-ccs-tlcm-fe10`, region `us-central1`, private GKE cluster `gcldccsinsght01` (lowercase `l`, not digit 1), namespace `ui-connector-dev-v3`.
- Deployment `adt-ui-connectorv2-1` (replicas pinned to 1 — hardcoded `server_id`; do not scale), Service `api-connector-service` (ClusterIP 80→8080, NEG), Ingress `api-connector-ingress` (class `gce-internal`, static IP `adtgcp-cent1-ccs-dev-insight-api-ip` = `100.73.16.94`, TLS via `ingress.gcp.kubernetes.io/pre-shared-cert`), BackendConfig `timeoutSec: 3600`.
- Redis Memorystore `100.72.86.38:6379`; upstream is Dialogflow CCAI → Pub/Sub → `adt-pubsub-interpreter` → Redis → this connector.
- CORS is `allow_origins=["*"]` — lock to Salesforce origins before production, but do NOT change it while debugging connectivity.

## 6. Operating constraints — obey strictly

1. **gcloud CLI quota is limited.** Minimize gcloud usage; batch commands; prefer GCP Console steps; ask before running more than 2–3 gcloud commands.
2. **kubectl does not work from Cloud Shell** (private cluster). Applies go through **Cloud Build**; connectivity tests run from the **bastion**.
3. Do not propose removing Cloud Run IAM / allowing unauthenticated — org policy, immovable.
4. Do not propose header-based auth, cookies, or subprotocol-header tricks for the LWC — the query-param token IS the chosen design; focus on making it work.

## 7. Bastion smoke test

```bash
TOKEN=$(gcloud auth print-identity-token)   # 1 CLI call, reuse for the hour
curl -vk "https://100.73.16.94/ws?token=${TOKEN}" \
  -H "Host: agentassist.adt.com" \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=="
```

HTTP `101 Switching Protocols` = the GKE path + query-param auth both work; remaining work is only the Salesforce/Apex side.
