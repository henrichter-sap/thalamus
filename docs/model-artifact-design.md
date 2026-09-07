# ModelArtifact

A `ModelArtifact` represents a set of model weights that live somewhere else —
a Hugging Face repo, an OCI image, an object-store bucket, a PVC — and
describes how to bring them into the cluster as a shared, local copy.

It answers three questions and only three: **which bytes** (and which version),
**how to fetch them**, and **where to keep the local copy**. How those bytes
get *served* is a separate concern and is not this resource's job.

## What a user writes

### A plain artifact

```yaml
apiVersion: thalamus.cloud/v1alpha1
kind: ModelArtifact
metadata:
  name: qwen3-8-27b
spec:
  base: hf://Qwen/Qwen3.8-27B
  materialize: true
  storage:
    storageClassName: ceph-rwx
  downloader:
    envFrom:
      - secretRef: hf-token
```

### An artifact with a speculative draft

```yaml
apiVersion: thalamus.cloud/v1alpha1
kind: ModelArtifact
metadata:
  name: qwen3-70b
spec:
  base: hf://org/Qwen3-70B
  draft: hf://org/Qwen3-70B-draft
  materialize: true
  storage:
    storageClassName: ceph-rwx
  downloader:
    containers:
      - name: downloader
        resources:
          limits: { cpu: "2", memory: 4Gi }
    envFrom:
      - secretRef: hf-token
    nodeSelector:
      intended-for: downloads
```

## Fields

- **`base`** — the primary weights, as a URI. The scheme selects the protocol:
  `hf://`, `oci://`, `s3://`, `pvc://`, … It is named for what it *means*
  (the model), not how it's encoded (a URI). Version pinning lives **in the
  URI**, using each protocol's native syntax (`@digest`, `:tag`, `@rev`,
  `?revision=`) — there is no separate revision field.
- **`draft`** — optional. The speculative draft weights, same URI shape. See
  "Draft models."
- **`materialize`** — when `true`, the operator runs a download Job to bring
  the weights into a cluster-local PVC, instead of leaving it to each
  consumer to pull at runtime.
- **`storage`** — where the local copy lives. The user sets the
  `storageClassName`; the **size is probed by the operator**, not guessed. An
  explicit size can still be given to override the probe.
- **`downloader`** — a full pod spec describing *how* to fetch. This is the
  only place credentials appear (`env` / `envFrom` from Secrets or
  ConfigMaps). It is merged over an opinionated operator base, so users can
  override anything that is safe to override (image, resources, node targeting,
  extra volumes for file-based creds) while the plumbing the operator injects
  (the PVC mount, the run mode, the service account) stays intact.

## Why

### Materialize once, share many

Without materialization, every consumer pulls the full weights from the remote
source at startup. For a 50 GB model across several replicas that is several
concurrent large downloads — slow first-ready, network-heavy, sensitive to
upstream rate limits (Hugging Face especially), and re-paid on every pod
restart or reschedule.

With it, one download Job pulls the weights a single time into a shared RWX
PVC, and every consumer mounts that PVC and loads from local disk. The first
pull pays for the download; every subsequent consumer — and every future
reschedule — is a fast local load. Scale-out becomes a batch of cheap local-disk
loads instead of a fan-out of remote pulls. As a side benefit it fits
air-gapped / edge topologies: pull once into the boundary, then serve locally.

### Size probed, not guessed

The user names a storage class, not a size. The operator reads each protocol's
metadata (HF file tree, OCI manifest, object-store listing) to determine the
weight size, applies headroom, and creates the PVC — biasing toward
over-provisioning, since an undersized PVC fails mid-download while an
oversized one just costs a little. This removes the "how big should this PVC
be?" guess from the user entirely.

### Credentials in exactly one place

All auth lives in the `downloader` pod spec. The controller never reads or
interprets the secrets, so it cannot leak them and stays agnostic about which
protocol or credential scheme is in use. Consumers of the artifact never mount
the token at all — only the short-lived downloader does — which shrinks the
secret's blast radius in a multi-tenant setup.

### One shape, any protocol

A single field (`base`, and optionally `draft`) covers every source because the
URI's scheme carries the protocol. Supporting a new source is a new download
handler, not a new API shape.

## Separation of concerns

Within the artifact, each kind of data has exactly one home:

| Concern                | Lives in                   | Why that owner                                      |
| ---------------------- | -------------------------- | --------------------------------------------------- |
| Which bytes, which version | `base` / `draft` (URI) | a self-contained locator; pinning is part of *what* you ask for |
| Credentials            | `downloader.env` / `envFrom` | only the component that hits the network needs them |
| Keep a local copy? where? | `materialize` + `storage` | the artifact's job is "give me a shared local copy" |
| How to fetch           | `downloader` (pod spec)    | one pod spec serves both the probe and the download Job |

In one line each: **the URI answers "which bytes," the downloader answers
"how do I get them," and `materialize` + `storage` answer "keep a local copy
where."** How those bytes are then served is a different resource's concern.

## Draft models

Speculative decoding comes in two flavors:

- **Self-MTP** — the draft heads are inside the `base` checkpoint. One weight
  set; nothing extra to declare.
- **Separate draft** — a second, smaller weight set is co-loaded with the
  target (classic `draft_model`, or an EAGLE head). Two weight sets.

Because a draft is never consumed on its own, it is **coupled into the target's
artifact** as the `draft` field rather than existing as a standalone,
addressable object. This buys several things at once:

- A draft has no independent identity, so it **cannot be accidentally used as
  if it were a real, standalone model**.
- The target↔draft pairing is fixed when the artifact is authored and reviewed
  once — the two cannot be mismatched.
- Materialization, readiness, and versioning collapse into **one unit**: one
  PVC, one probe (summing both), one download, one version clock. Re-pulling
  the artifact updates both atomically.

The trade-off is that a draft cannot double as a standalone weight set. That is
accepted for now; if it ever becomes real, the draft moves back out to its own
artifact.

## Lifecycle

1. **Probe** — the operator runs the `downloader` pod in probe mode to read the
   artifact's size from protocol metadata (no download).
2. **Size the PVC** — the operator creates an operator-owned PVC from the
   probed size plus headroom.
3. **Download** — the `downloader` pod runs in download mode, pulling `base`
   (and `draft`, if present) into the PVC.
4. **Ready** — the artifact reports `Ready` once the download completes,
   exposing the local path, the PVC, and the probed/actual sizes.

A serving resource references the Ready artifact by name and mounts the PVC;
that step is out of scope here.

## Open items

- Operator auto-resize-and-retry of the PVC on `ENOSPC`, in case a download
  outgrows the probed size.
- A cheap sanity warning when a `draft` probes larger than its `base`.
- Per-set credentials, if `base` and `draft` ever come from genuinely different
  sources (today they share the `downloader`'s credentials).
- The storage strategy: one PVC per artifact versus one shared PVC with a
  sub-path per artifact.
