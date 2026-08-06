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

### Working files produced by this runbook

| File | Created in | Purpose |
|---|---|---|
| `clean-cert.pem` | Step 2 | Preamble stripped, order not yet corrected |
| `clean-key.pem` | Step 2 | Cleaned private key — used through to the end |
| `part-NN.pem` | Step 3 | Individual certificates split out of the chain |
| `chain.pem` | Step 3 | **Correctly ordered chain — this is what gets uploaded** |

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

### Confirmed findings for this bundle (2026-08-06)

| Check | Result |
|---|---|
| PEM line 1 | `Bag Attributes` / `friendlyName` / `localKeyID` — PKCS#12 export preamble present |
| Key header | `-----BEGIN PRIVATE KEY-----` — unencrypted, no decrypt step needed |
| Certificate count | `3` — leaf plus two intermediates |
| Chain order | **Wrong** — intermediate first. See Step 3 |

The `Bag Attributes` preamble is what produced the `unexpected data before 1PEM block` error in the console upload.

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
grep -c "Bag Attributes" clean-cert.pem
```

Expect `-----BEGIN CERTIFICATE-----`, a certificate count of `3`, a `Bag Attributes` count of `0`, and an intact key header.

The `awk` range only emits text between BEGIN and END markers, so it also drops `Bag Attributes` blocks interleaved *between* certificates — PKCS#12 exports typically place one before each.

> Cleaning does not reorder anything. `clean-cert.pem` still carries whatever order the source had. Step 3 handles that.

---

## Step 3 — Check chain order FIRST

> **Do this before the modulus comparison.** `openssl x509` reads only the **first** certificate in a multi-cert file. If the chain is out of order, every subsequent check silently inspects the wrong certificate — including the key-match test, which will report a false mismatch.

**Observed on this bundle (2026-08-06):** the chain was ordered intermediate-first. `openssl x509 -subject` on `clean-cert.pem` returned:

```
subject=C = GB, O = Sectigo Limited, CN = Sectigo Public Server Authentication CA OV R36
issuer=C = GB, O = Sectigo Limited, CN = Sectigo Public Server Authentication Root R46
notBefore=Mar 22 00:00:00 2021 GMT
notAfter=Mar 21 23:59:59 2036 GMT
```

Three tells that this is **not** the leaf:

| Signal | Leaf | CA |
|---|---|---|
| Subject CN | your hostname | contains `CA`, `Root`, or the issuer's name |
| Validity span | ~1 year (398 days max) | 10–20 years |
| SAN present | yes | absent |

A 15-year lifetime with a Sectigo CA subject is an intermediate. GCP requires leaf-first and will reject the upload.

### Split and identify every certificate

```bash
cd ~/certificates
csplit -z -f part- -b '%02d.pem' clean-cert.pem '/-----BEGIN CERTIFICATE-----/' '{*}'

for f in part-*.pem; do
  echo "=== $f ==="
  openssl x509 -in "$f" -noout -subject -issuer -dates
done
```

Identify the **leaf**: subject CN matches your hostname, short validity, and it is the only one carrying a SAN.

### Rebuild in the correct order

Order is leaf → the cert that issued the leaf → the cert that issued that one. Chain them by matching each certificate's `issuer` string to the next certificate's `subject` string.

```bash
cat part-<LEAF>.pem part-<INTERMEDIATE>.pem part-<ROOT>.pem > chain.pem
```

Root is optional in the chain; intermediates are not.

### Confirm the rebuild

```bash
openssl crl2pkcs7 -nocrl -certfile chain.pem | openssl pkcs7 -print_certs -noout
openssl x509 -in chain.pem -noout -subject -dates
```

The first subject printed must now be your server certificate with a ~1 year validity.

**From this point forward, use `chain.pem` — not `clean-cert.pem` — everywhere below.**

---

## Step 4 — Verify the key matches the certificate

Only meaningful once Step 3 confirms the leaf is first.

```bash
openssl x509 -noout -modulus -in chain.pem     | openssl md5
openssl rsa  -noout -modulus -in clean-key.pem | openssl md5
```

**Both hashes must be identical.**

If they differ, check the leaf directly before concluding anything:

```bash
openssl x509 -noout -modulus -in part-<LEAF>.pem | openssl md5
```

A mismatch that persists against the isolated leaf is a genuine key/certificate mismatch — re-export the pair from the source bundle. A mismatch only against `chain.pem` means the concatenation put the wrong certificate first.

---

## Step 5 — Verify the SAN covers the TST hostname

This is the check most likely to stop the whole exercise.

```bash
openssl x509 -in chain.pem -noout -text | grep -A1 "Subject Alternative Name"
openssl x509 -in chain.pem -noout -dates
openssl x509 -in chain.pem -noout -subject -issuer
```

> An empty SAN result is itself diagnostic — CA certificates have no SAN. If nothing prints, the first certificate in the file is still not the leaf. Return to Step 3.

The SAN list must contain the **actual TST hostname** the Ingress will serve. The files are named for the apex (`agentassist.adt.com`), but TST traffic likely arrives on something like `tst.agentassist.adt.com`. A certificate for the apex will not validate a subdomain unless the SAN is a wildcard (`*.agentassist.adt.com`) or lists the subdomain explicitly.

If the hostname is missing, **stop and request a reissue from the CA.** Everything downstream will appear to succeed and then fail at TLS handshake.

Also confirm `notAfter` is comfortably in the future and reflects a server certificate lifetime, not a CA one.

---

## Step 6 — Identify the TST region

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

## Step 7 — Create the classic regional SSL certificate

```bash
gcloud compute ssl-certificates create agentassist-adt-com-2026 \
  --certificate=chain.pem \
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

## Step 8 — Annotate the Ingress

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

## Step 9 — Watch the reconcile

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

## Step 10 — Verify the TLS handshake

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
| Modulus hashes differ | Usually the chain is out of order, so `openssl x509` is reading an intermediate rather than the leaf | Step 3 — split, identify the leaf, compare against the leaf directly before concluding mismatch |
| Modulus still differs against the isolated leaf | Genuine key/certificate mismatch | Re-export the pair from the source bundle |
| SAN grep returns nothing | First certificate in the file is a CA, not the leaf | Step 3 — rebuild leaf-first |
| Subject CN is a CA name, validity spans 10+ years | Chain is intermediate-first | Step 3 |
| Cert created but Ingress unchanged | Controller still reconciling, or erroring for an unrelated reason | Check `kubectl describe ingress` events |
| Ingress controller 409-looping | IP reserved with `GCE_ENDPOINT` purpose instead of `SHARED_LOADBALANCER_VIP` (known issue on DEV) | Immutable — network team must re-reserve. Not certificate-related |
| Handshake fails, cert looks correct | SAN does not cover the requested hostname | Step 5 — reissue required |
| `Verify return code: 21` (unable to verify first cert) | Intermediate missing from the chain | Concatenate leaf + intermediate(s) into `chain.pem` |
| GCP rejects the upload citing chain order | Leaf is not the first certificate | Step 3 |

---

## Note on the F5 XC edge

If F5 XC remains the public edge terminating TLS for this hostname, the certificate installed here covers only the **internal hop** — F5 to ILB. F5 must either trust this CA chain or have origin-pool verification configured accordingly. A clean handshake at the ILB does not by itself mean the path works end-to-end from the public edge.

---

## Alternative: Kubernetes TLS Secret

If a fully GitOps flow is preferred with nothing created out-of-band:

```bash
kubectl create secret tls agentassist-tls \
  --cert=chain.pem \
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
rm -f part-*.pem
```

Remove private key material from Cloud Shell once the certificate resource exists. The certificate itself is not sensitive; the key is.
