# UI Connector — Build & Push to TST Artifact Registry

**Source project (existing image):** `adtgcp-ent-dev-ccs-tlcm-fe10`
**Target project:** `adtgcp-ent-tst-ccs-tlcm-8143`
**Region:** `us-central1`
**Repository:** `ui-connector` (Docker format)
**Workload:** `adt-ui-connectorv2-1`, namespace `ui-connector`

---

## Two paths

| Path | When to use | Section |
|---|---|---|
| **Build from source** | Code has changed since the DEV image was built, or TST needs a different build | Path A |
| **Copy the DEV image** | The DEV image is already what you want in TST | Path B |

Path B is faster, runs server-side, and guarantees byte-identical artifacts across environments. Prefer it unless the code differs.

---

## Step 0 — Set variables

```bash
export TST_PROJECT=adtgcp-ent-tst-ccs-tlcm-8143
export DEV_PROJECT=adtgcp-ent-dev-ccs-tlcm-fe10
export REGION=us-central1
export REPO=ui-connector
export IMAGE=ui-connector
export TAG=v2
```

Confirm the active account and project:

```bash
gcloud config list
```

Expect `account = v_avinashsharma@adt.com`.

---

## Step 1 — Enable APIs

```bash
gcloud services enable \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  --project=$TST_PROJECT
```

`cloudbuild.googleapis.com` is only needed for Path A. Enabling both is harmless.

---

## Step 2 — Create the repository

The TST project will not have this repository yet.

```bash
gcloud artifacts repositories create $REPO \
  --repository-format=docker \
  --location=$REGION \
  --description="UI connector WebSocket gateway — TST" \
  --project=$TST_PROJECT
```

Verify:

```bash
gcloud artifacts repositories list \
  --location=$REGION \
  --project=$TST_PROJECT
```

> If this errors with `ALREADY_EXISTS`, the repo is there — carry on.

---

## Path A — Build from source

Run from the directory containing the `Dockerfile`.

```bash
gcloud builds submit \
  --tag=$REGION-docker.pkg.dev/$TST_PROJECT/$REPO/$IMAGE:$TAG \
  --project=$TST_PROJECT \
  --region=$REGION \
  .
```

Cloud Build performs both the build and the push. No local Docker daemon required — this matters in Cloud Shell, which has limited local build capacity.

### If the build fails on staging

A failure that references the staging bucket or a missing service account — rather than the build itself — usually means a VPC Service Controls perimeter or an org policy blocking the default Cloud Build service account. Two options:

1. Switch to Path B, which sidesteps Cloud Build entirely.
2. Specify an explicit bucket you control:

```bash
gcloud builds submit \
  --tag=$REGION-docker.pkg.dev/$TST_PROJECT/$REPO/$IMAGE:$TAG \
  --gcs-source-staging-dir=gs://<your-bucket>/source \
  --project=$TST_PROJECT \
  --region=$REGION \
  .
```

---

## Path B — Copy the DEV image

List what is available on the DEV side first:

```bash
gcloud artifacts docker tags list \
  $REGION-docker.pkg.dev/$DEV_PROJECT/$REPO/$IMAGE \
  --project=$DEV_PROJECT
```

Copy across projects:

```bash
gcloud artifacts docker images copy \
  $REGION-docker.pkg.dev/$DEV_PROJECT/$REPO/$IMAGE:$TAG \
  $REGION-docker.pkg.dev/$TST_PROJECT/$REPO/$IMAGE:$TAG
```

This is a server-side registry-to-registry copy — nothing transits Cloud Shell.

**Required permissions on your account:**

| Project | Role |
|---|---|
| DEV | `roles/artifactregistry.reader` |
| TST | `roles/artifactregistry.writer` |

---

## Step 3 — Confirm the image landed

```bash
gcloud artifacts docker images list \
  $REGION-docker.pkg.dev/$TST_PROJECT/$REPO/$IMAGE \
  --include-tags \
  --project=$TST_PROJECT
```

**Record the digest from this output.** Pin the manifest to the digest rather than the `:v2` tag — mutable tags have previously caused stale-image deployments (the same class of problem as Cloud Run's "Edit & Deploy New Revision" reusing an existing image instead of rebuilding).

---

## Step 4 — Grant the TST cluster pull access

Without this, pods fail with `ImagePullBackOff`.

Find the project number:

```bash
gcloud projects describe $TST_PROJECT --format="value(projectNumber)"
```

Identify the service account the nodes actually run as:

```bash
gcloud container clusters describe <TST_CLUSTER_NAME> \
  --region=$REGION \
  --project=$TST_PROJECT \
  --format="value(nodeConfig.serviceAccount)"
```

If that returns `default`, the nodes use the default compute service account:

```bash
gcloud artifacts repositories add-iam-policy-binding $REPO \
  --location=$REGION \
  --member="serviceAccount:<PROJECT_NUMBER>-compute@developer.gserviceaccount.com" \
  --role="roles/artifactregistry.reader" \
  --project=$TST_PROJECT
```

If it returns a custom service account, substitute that address in `--member`.

Verify the binding:

```bash
gcloud artifacts repositories get-iam-policy $REPO \
  --location=$REGION \
  --project=$TST_PROJECT
```

---

## Step 5 — Update the manifest

In `deployment-tst.yaml`, replace the placeholder image line for `adt-ui-connectorv2-1`:

```yaml
image: us-central1-docker.pkg.dev/adtgcp-ent-tst-ccs-tlcm-8143/ui-connector/ui-connector@sha256:<DIGEST_FROM_STEP_3>
```

Apply and watch the rollout:

```bash
kubectl apply -f deployment-tst.yaml
kubectl rollout status deployment/adt-ui-connectorv2-1 -n ui-connector
kubectl get pods -n ui-connector -w
```

---

## The bq-operations image

The second deployment pulls from a different DEV repository (`cloud-run-source-deploy`) and is already digest-pinned. Same treatment:

```bash
gcloud artifacts repositories create cloud-run-source-deploy \
  --repository-format=docker \
  --location=$REGION \
  --project=$TST_PROJECT

gcloud artifacts docker images copy \
  $REGION-docker.pkg.dev/$DEV_PROJECT/cloud-run-source-deploy/bq-operations@sha256:76287878936d17ea315ef7ade21a2963bb7962c184ec3b6c108f0e1337f38c18 \
  $REGION-docker.pkg.dev/$TST_PROJECT/cloud-run-source-deploy/bq-operations:tst-v1
```

Then grant the same reader binding on that repository and update its image line in the manifest.

---

## Alternative: keep pulling from the DEV repository

Rather than copying images, the TST cluster's service account can be granted read access on the DEV repository directly:

```bash
gcloud artifacts repositories add-iam-policy-binding $REPO \
  --location=$REGION \
  --member="serviceAccount:<TST_PROJECT_NUMBER>-compute@developer.gserviceaccount.com" \
  --role="roles/artifactregistry.reader" \
  --project=$DEV_PROJECT
```

Fewer moving parts, and no image drift between environments. The tradeoff is a cross-project runtime dependency: TST workloads will fail to schedule if the DEV project is unavailable, and a DEV repository cleanup policy could delete an image TST is still running. For a short-lived TST environment this is usually acceptable; for anything longer-lived, copy the images.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ImagePullBackOff` | Node service account lacks reader on the repository | Step 4 |
| `denied: Permission artifactregistry.repositories.uploadArtifacts denied` | Your account lacks writer on the target | Request `roles/artifactregistry.writer` on TST |
| `NOT_FOUND: Repository "ui-connector" not found` | Repository not created, or wrong region | Step 2 — region must match the image path |
| Build fails referencing a staging bucket | VPC-SC perimeter or org policy on Cloud Build | Use Path B, or `--gcs-source-staging-dir` |
| Pod runs old code after redeploy | Mutable tag resolved to a cached image | Pin by digest, not tag |
| `images copy` fails on the source | Missing reader on DEV | Request `roles/artifactregistry.reader` on DEV |
