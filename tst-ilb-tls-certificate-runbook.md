# TLS Certificate Setup — TST Internal ALB (agentassist.adt.com)

**Project:** `adtgcp-ent-tst-ccs-tlcm-8143`
**Account:** `v_avinashsharma@adt.com`
**Environment:** TST
**Working directory:** Cloud Shell, `~/certificates`
**Approach:** Classic `compute ssl-certificates` + GKE Ingress `pre-shared-cert` annotation

---

## Why classic and not Certificate Manager

GKE Ingress has no annotation that consumes a Certificate Manager certificate map. The only cert sources a GKE Ingress understands are:

| Source | Annotation / field | Works here? |
|---|---|---|
| Classic SSL certificate | `networking.gke.io/pre-shared-cert` | **Yes** |
| Kubernetes TLS Secret | `spec.tls[].secretName` | Yes (alternative) |
| ManagedCertificate CRD | `networking.gke.io/managed-certificates` | No — Google-issued, external LB only |
| Certificate Manager map | `networking.gke.io/certmap` | No — GKE **Gateway** only, not Ingress |

Certificate Manager maps bind directly to a target HTTPS proxy. Since the Ingress controller owns and reconciles that proxy, anything attached out-of-band gets overwritten on the next sync. Hence: classic.

The "Create certificate" console screen can be abandoned.

---

## Prerequisites

Files present in `~/certificates` (uploaded from the VDI):

- `agentassist.adt.com.pem` — certificate chain
- `agentassist.adt.com.key` — private key

Ignore the rest of the bundle — they target other platforms:

| File | Platform |
|---|---|
| `.jks` | Java keystore |
| `.kdb` / `.sth` | IBM HTTP Server |
| `.p12` | Windows / IIS |
| `.rdb` | Request database |
| `.csr` | Original signing request |
| `.cer` | Leaf only, DER/Base64 — not the chain |

> **Keep the originals on the VDI** until the certificate is created and verified. Cloud Shell home storage is reclaimed after prolonged inactivity.

---

## Step 1 — Inspect the files

```bash
cd ~/certificates
head -3 agentassist.adt.com.pem
head -1 agentassist.adt.com.key
grep -c "BEGIN CERTIFICATE" agentassist.adt.com.pem
```

**Expected:**

- PEM line 1 is exactly `-----BEGIN CERTIFICATE-----`
- Key line 1 is `-----BEGIN PRIVATE KEY-----` or `-----BEGIN RSA PRIVATE KEY-----`
- Certificate count is 2 or more (leaf + intermediate(s))

**If PEM line 1 is anything else** — `Bag Attributes`, `subject=`, `issuer=`, or blank — that is the cause of the `unexpected data before 1PEM block` error. Step 2 fixes it.

**If the key says `-----BEGIN ENCRYPTED PRIVATE KEY-----`** — stop. It is passphrase-protected and GCP will reject it. Decrypt with the passphrase from whoever generated it:

```bash
openssl rsa -in agentassist.adt.com.key -out agentassist.adt.com.key.dec
```

**If the certificate count is 1** — the file holds only the leaf. Obtain the intermediate(s) from the CA and concatenate leaf-first before proceeding.

---

## Step 2 — Clean both files

Run this regardless of what Step 1 showed. It strips UTF-8 BOM, metadata preamble, and Windows CRLF line endings in one pass.

```bash
awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' \
  agentassist.adt.com.pem > clean-cert.pem

awk '/-----BEGIN/,/-----END/' \
  agentassist.adt.com.key > clean-key.pem

sed -i 's/\r$//' clean-cert.pem clean-key.pem
```

Confirm the cleaned output:

```bash
head -1 clean-cert.pem
head -1 clean-key.pem
grep -c "BEGIN CERTIFICATE" clean-cert.pem
```

---

## Step 3 — Verify the key matches the certificate

Mismatch is the single most common cause of a silent failure that only surfaces at handshake time.

```bash
openssl x509 -noout -modulus -in clean-cert.pem | openssl md5
openssl rsa  -noout -modulus -in clean-key.pem  | openssl md5
```

**Both hashes must be identical.** If they differ, the key does not belong to this certificate — go back to the source bundle.

---

## Step 4 — Verify the SAN covers the TST hostname

This is the check most likely to stop the whole exercise.

```bash
openssl x509 -in clean-cert.pem -noout -text | grep -A1 "Subject Alternative Name"
openssl x509 -in clean-cert.pem -noout -dates
openssl x509 -in clean-cert.pem -noout -subject -issuer
```

The SAN list must contain the **actual TST hostname** the Ingress will serve. The files are named for the apex (`agentassist.adt.com`), but TST traffic likely arrives on something like `tst.agentassist.adt.com`. A certificate for the apex will not validate a subdomain unless the SAN is a wildcard (`*.agentassist.adt.com`) or lists the subdomain explicitly.

If the hostname is missing, **stop and request a reissue from the CA.** Everything downstream will appear to succeed and then fail at TLS handshake.

Also confirm `notAfter` is comfortably in the future.

Verify the chain order while here:

```bash
openssl crl2pkcs7 -nocrl -certfile clean-cert.pem \
  | openssl pkcs7 -print_certs -noout
```

Leaf subject must appear first, then intermediate(s), then root (root optional).

---

## Step 5 — Identify the TST region

Do **not** assume `us-central1` — that is the DEV cluster's region. TST may differ.

```bash
gcloud config list

gcloud container clusters list

gcloud compute forwarding-rules list \
  --filter="loadBalancingScheme=INTERNAL_MANAGED" \
  --format="table(name,region,IPAddress,target)"
```

Note the region returned. It is referred to below as `<REGION>`.

---

## Step 6 — Create the classic regional SSL certificate

```bash
gcloud compute ssl-certificates create agentassist-adt-com-2026 \
  --certificate=clean-cert.pem \
  --private-key=clean-key.pem \
  --region=<REGION> \
  --project=adtgcp-ent-tst-ccs-tlcm-8143
```

`--region` is mandatory. A regional internal ALB cannot consume a global certificate.

The year suffix in the name is deliberate — at renewal you create `agentassist-adt-com-2027`, flip the annotation, confirm, then delete the old one. No downtime, and the annotation accepts a comma-separated list if you want both attached during cutover.

**Verify:**

```bash
gcloud compute ssl-certificates describe agentassist-adt-com-2026 \
  --region=<REGION> \
  --format="value(name,expireTime,subjectAlternativeNames)"
```

---

## Step 7 — Annotate the Ingress

Edit the TST Ingress manifest in the repo:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: <your-ingress-name>
  namespace: ui-connector
  annotations:
    kubernetes.io/ingress.class: "gce-internal"
    networking.gke.io/pre-shared-cert: "agentassist-adt-com-2026"
    kubernetes.io/ingress.allow-http: "false"
spec:
  rules:
  - host: <tst-hostname>
    http:
      paths:
      - path: /*
        pathType: ImplementationSpecific
        backend:
          service:
            name: <service-name>
            port:
              number: <port>
```

The annotation takes the certificate **name only** — never a file path, never a region. The controller resolves it within the Ingress's own region.

Apply:

```bash
kubectl apply -f ingress.yaml -n ui-connector
```

---

## Step 8 — Watch the reconcile

```bash
kubectl describe ingress <name> -n ui-connector
```

Read the **Events** section. Reconciliation is not instant — allow several minutes for the controller to push the certificate to the target proxy.

Confirm from the load balancer side:

```bash
gcloud compute target-https-proxies list --regions=<REGION>

gcloud compute target-https-proxies describe <proxy-name> \
  --region=<REGION> \
  --format="value(sslCertificates)"
```

The output should reference `agentassist-adt-com-2026`.

---

## Step 9 — Verify the TLS handshake

From the bastion (which has network reach to the ILB):

```bash
openssl s_client -connect <ILB_IP>:443 \
  -servername <tst-hostname> </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

For the full verification result including chain validation:

```bash
openssl s_client -connect <ILB_IP>:443 \
  -servername <tst-hostname> </dev/null 2>&1 | grep -E "Verify return code|subject=|issuer="
```

Target: `Verify return code: 0 (ok)`.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `unexpected data before 1PEM block` | BOM, Bag Attributes, or blank lines above the first PEM header | Step 2 |
| Modulus hashes differ | Key does not match certificate | Re-export the pair from the source bundle |
| Cert created but Ingress unchanged | Controller still reconciling, or erroring for an unrelated reason | Check `kubectl describe ingress` events |
| Ingress controller 409-looping | IP reserved with `GCE_ENDPOINT` purpose instead of `SHARED_LOADBALANCER_VIP` (known issue on DEV) | Immutable — network team must re-reserve. Not certificate-related |
| Handshake fails, cert looks correct | SAN does not cover the requested hostname | Step 4 — reissue required |
| `Verify return code: 21` (unable to verify first cert) | Intermediate missing from the chain | Concatenate leaf + intermediate(s) into `clean-cert.pem` |

---

## Note on the F5 XC edge

If F5 XC remains the public edge terminating TLS for this hostname, the certificate installed here covers only the **internal hop** — F5 to ILB. F5 must either trust this CA chain or have origin-pool verification configured accordingly. A clean handshake at the ILB does not by itself mean the path works end-to-end from the public edge.

---

## Alternative: Kubernetes TLS Secret

If a fully GitOps flow is preferred with nothing created out-of-band:

```bash
kubectl create secret tls agentassist-tls \
  --cert=clean-cert.pem \
  --key=clean-key.pem \
  -n ui-connector
```

```yaml
spec:
  tls:
  - secretName: agentassist-tls
    hosts:
    - <tst-hostname>
```

Functionally equivalent — GKE converts the Secret into a classic SSL certificate behind the scenes. The tradeoff is that the private key then lives in etcd and in whatever repository holds the manifest. For a client-issued CA certificate, `pre-shared-cert` keeps the key out of the cluster entirely and is generally preferred.

---

## Cleanup after verification

```bash
shred -u clean-key.pem agentassist.adt.com.key 2>/dev/null || rm -f clean-key.pem agentassist.adt.com.key
```

Remove private key material from Cloud Shell once the certificate resource exists. The certificate itself is not sensitive; the key is.
