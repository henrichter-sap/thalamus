# Model

A `Model` serves a materialized [`ModelArtifact`](./model-artifact-design.md). It is a **standard pod spec** (the inference engine) plus two fields — `artifact` (which artifact to serve) and `replicas` (how many engine replicas). It is the "how do I run it" half of the split; the artifact is the "which bytes."

The operator runs two workloads per `Model`: the **engine** (your pod spec) and the Model's **own EPP** (the router). This doc also covers the two things the operator adds around a `Model`: the **defaults floor** (the platform's opinionated, always-on configuration) and the **EPP** (per-Model, with a platform-standard policy).

## What a user writes

### Serve a plain artifact

```yaml
apiVersion: thalamus.cloud/v1alpha1
kind: Model
metadata:
  name: qwen3-8-27b
spec:
  artifact: qwen3-8-27b
  replicas: 2
  # everything below is a standard pod spec
  containers:
    - name: engine  # required
      # image omitted — taken from the floor
      args:
        - --tensor-parallel-size=2
      resources:
        limits:
          nvidia.com/gpu: "2"
  nodeSelector:
    nvidia.com/gpu.product: NVIDIA-H200
```

The common case needs only the artifact, a replica count, the GPU count, and the GPU type. The image and the always-on engine flags come from the floor. A vLLM recipe maps in 1:1 — the `spec` is a pod spec, so there is nothing thalamus-specific to learn.

### Serve a speculative artifact

```yaml
apiVersion: thalamus.cloud/v1alpha1
kind: Model
metadata:
  name: qwen3-70b
spec:
  artifact: qwen3-70b
  replicas: 1
  containers:
    - name: engine
      args:
        # speculative behavior — yours to set
        - --speculative-config={"method":"draft_model","num_speculative_tokens":3}
        - --tensor-parallel-size=8
      resources:
        limits:
          nvidia.com/gpu: "8"
  nodeSelector:
    nvidia.com/gpu.product: NVIDIA-H200
```

You set the speculative *behavior* (method, token count) as engine args. The *location* of the draft is not yours to set — the operator injects the materialized local path. See "Model and draft paths."

### (Optional) Size this Model's EPP

Each Model runs its own EPP, sized from the floor by default. If one Model needs a bigger (or smaller) EPP, add an `epp` container — no separate field:

```yaml
spec:
  artifact: qwen3-70b
  replicas: 1
  containers:
    - name: engine
      args:
        - --tensor-parallel-size=8
      resources: {limits: {nvidia.com/gpu: "8"}}
    - name: epp  # optional — overrides this Model's EPP container
      resources:
        limits: {memory: 8Gi, cpu: "4"}
  nodeSelector:
    nvidia.com/gpu.product: NVIDIA-H200
```

Most Models never include an `epp` container.

## Fields

- **`artifact`** — the `ModelArtifact` to serve, by name (same namespace).
- **`replicas`** — engine replicas. The scaling knob.
- **(inline pod spec)** — a standard `corev1.PodSpec` for the engine: `containers`, `volumes`, `nodeSelector`, `affinity`, `tolerations`, `serviceAccountName`, … A vLLM recipe drops in unchanged.

**We don't lift vLLM args to top-level fields.** `--served-model-name`, `--tensor-parallel-size`, `--speculative-config`, `--block-size`, and the rest stay engine args; the operator reads whatever it needs from them (the served names for pool registration, the block size for the EPP mirror, the speculative `model` field). The only top-level fields are the thalamus-level ones — `artifact` and `replicas` — which have no vLLM or k8s equivalent.

### Containers are routed by name

The operator splits `containers` by name:

| container | goes to |
|-----------|---------|
| `engine` (required, exactly one) | the engine `Deployment`'s container |
| `epp` (optional) | merged over the floor EPP defaults → this Model's EPP `Deployment` |
| anything else | an engine sidecar (runs with the engine) |

The pod-level fields (`nodeSelector`, `volumes`, `tolerations`, …) apply to the **engine** pod only. The EPP pod's pod-level fields come from the operator defaults — an EPP is a small (typically CPU) pod, not a GPU pod.

### Model and draft paths

You never write a weights *location*. The operator always points the engine at the materialized local copy of the artifact's `base` (the primary model).

For the draft, the rule is precise: if your engine args contain a non-empty `--speculative-config` **and** the artifact has a `draft`, the operator sets the `model` field inside that `--speculative-config` to the local predownloaded draft path, overriding whatever value is written there. Every other field in the config (`num_speculative_tokens`, `method`, …) is left as you wrote it. With no `--speculative-config`, or no `draft` in the artifact, the operator touches nothing — so self-MTP configs (`method: mtp`, no draft) pass through unchanged.

You write the speculative config exactly as you would for vLLM; the operator is responsible only for making the `model` field point at the local draft instead of a repo id.

## Why

### The engine is yours

The engine is a *workload* concern. It varies per model, the author has real domain knowledge (their model, their GPU, their args), and the blast radius of a wrong choice is bounded and reviewable — the model runs slower or doesn't fit, and it shows up immediately. So it is an open pod spec: override anything that is safe to override. Because the `spec` *is* a pod spec, a vLLM recipe drops in with no field translation — the controller adds behavior around the pod, it does not restructure it.

### The EPP policy is the platform's

The EPP is **per-Model** — each `Model` runs its own EPP and pool. But the EPP's *policy* (routing strategy, flow control) is closed and **standard**:

- The good routing answer is essentially the same for almost every model, and the author has no domain expertise here.
- A wrong choice is **high-cost and invisible**. It rarely fails loudly; it just routes suboptimally — KV-cache-aware routing off recomputes prefill a better-placed replica already had (p99 latency and GPU cost creep up), or a mis-set saturation threshold either queues requests it shouldn't or admits too many (tail-latency spikes, OOM).
- It has **hidden couplings to engine internals** — the KV block size and the ZMQ/metrics ports are properties of the *engine* that the EPP must match. Asking an author to keep those consistent by hand is an invisible-coupling footgun by construction.

So the policy lives in a **shared, standard ConfigMap** the platform manages — the same for every EPP — and the operator keeps the engine-to-EPP contract consistent. What a Model *can* touch is its EPP's **container** (image/resources), via the optional `epp` container, for the occasional "this model needs a bigger router."

### The floor makes the common case trivial

The always-on engine flags and image are not per-model choices — they are the platform's way of running vLLM. Keeping them in one explicit place (the floor, below) means the common-case `Model` is a few lines, and "where do these defaults come from?" has a concrete, readable answer.

### The same rule, three resources

Engine, EPP, and the artifact's downloader all follow the same shape: an opinionated **floor** + an **object** that overrides/augments it + **derived** values the operator injects. They differ only in how open the *object* layer is — a full, open pod spec for the engine and downloader (real variation, reviewable blast radius), and a **standard policy** for the EPP (little variation, invisible blast radius) with only its container sizing open to a per-Model override. "Engine: here's your pod spec," "EPP: the policy is standard, the sizing is yours to bump," are the same rule applied to different kinds of thing.

## Operator defaults (the floor)

The operator owns a set of defaults — the "floor" — for the parts of a workload that are the platform's to decide rather than the author's. Instead of baking these into the operator binary, they live in a single ConfigMap so they are explicit, inspectable, and editable per cluster — no CRD.

### The defaults ConfigMap

A single `ConfigMap` in the operator namespace. Each top-level **key names a resource kind** and holds that kind's default spec as a YAML document; the operator reads the key matching the object it it is reconciling.

| key | applies to | holds |
|-----|------------|-------|
| `engine.yaml` | a `Model`'s `engine` container | default image, always-on args, env |
| `epp.yaml` | a `Model`'s EPP container | default EPP image, resources |
| `downloader.yaml` | a `ModelArtifact`'s downloader | default downloader pod spec |

```yaml
kind: ConfigMap
metadata: {name: thalamus-defaults, namespace: thalamus-system}
data:
  engine.yaml: |
    image: keppel.../vllm/vllm-openai:v0.28.0
    args:
      - --enable-prefix-caching
      - --enable-prompt-tokens-details
      - --enable-auto-tool-choice
      - --disable-uvicorn-access-log
      - --gpu-memory-utilization=0.95
      - --block-size=16             # default; a model may override
    env:
      - {name: NCCL_IB_DISABLE, value: "1"}
  epp.yaml: |
    image: keppel.../llm-d/llm-d-router-endpoint-picker:v0.9.0
    resources:
      requests: {cpu: "1", memory: 1Gi}
      limits:   {memory: 2Gi}
  downloader.yaml: |
    image: keppel.../thalamus-downloader:v1
    resources:
      requests: {cpu: 1, memory: 1Gi}
```

It is rendered from Helm values, so it is per-cluster, lives in git, and changes go through normal review. The operator watches it and applies changes without a redeploy.

The EPP **policy** is *not* in this map. It is a separate **shared, standard ConfigMap** (also rendered by Helm) mounted by every EPP — the same routing / flow-control config for all EPPs. It is platform-managed and not per-Model.

### How defaults compose

Three layers, lowest to highest precedence:

1. **Floor** — the matching ConfigMap entry. It contributes defaults.
2. **Object** — the object's own spec. Overrides or augments the floor.
3. **Computed** — values the operator derives and injects (the model and draft paths, the ZMQ/metrics ports, and a default `--served-model-name` when the engine sets none). Not user-settable.

Args merge by *flag name*: the object's value wins for a flag the floor also sets, and floor-only flags are retained. That is what lets a model override one floor default (say `--block-size`) without dropping the floor's other always-on args.

Some engine values are **EPP-visible**: the EPP must use the same value as the engine for KV-cache-aware routing to be correct. The KV block size is the main one. The floor sets a default and a model may override it — some models require a specific size and won't run below it — and the operator mirrors the *resolved* value into the EPP.

The operator applies the composed result to the children it owns — the engine `Deployment`, the EPP `Deployment`, and the downloader `Job` — the resolved, authoritative configuration; inspect them to see exactly what runs. `status` carries state and health (phase, conditions, readiness), not a copy of the spec. A single provenance marker (the observed defaults generation) records where the floor came from, should auditability of defaults matter.

### The EPP (per-Model)

Each `Model` runs its **own** EPP `Deployment` and its **own** pool — not a shared, cluster-wide EPP. The operator renders, per Model:

- the **engine** `Deployment` + `Service` (from the inline pod spec, minus the `epp` container, with the operator injections);
- the **EPP** `Deployment` — the floor EPP container (`epp.yaml`) merged with the Model's `epp` container (if present), the shared policy ConfigMap mounted, and operator-computed env (pool name, engine endpoint);
- the **pool** — the EPP's pool, pointing at the engine `Service`, registered under every served name (`--served-model-name`) so a request for any of them routes here.

So the EPP is: **policy** from the shared standard ConfigMap (same for all), **container** from the floor with an optional per-Model override, and **topology** (that it exists at all, per-Model) decided by the operator. EPP topology is an operator decision the `Model` never expresses beyond the optional `epp` container.

### Guarantees and failure modes

- **Fail closed.** The operator validates the ConfigMap on load; an invalid entry is rejected and the last-good defaults are kept.
- **Fleet-wide blast radius.** Editing the floor touches every object relying on it — inherent to a shared default. Mitigated by gitops review, fail-closed validation, and the additive floor (an object can pin its own value to opt out of a bad default).
- **No schema validation.** A ConfigMap is not schema-checked, so a bad flag reaches the engine and surfaces as an engine failure in the object's status. This is the main thing a CRD would have given us for free.

## Separation of concerns

Each concern has one owner:

| Concern | Owner / where | Why |
|---------|---------------|-----|
| Which weights to serve | `Model.spec.artifact` | serving references the bytes; it doesn't own them |
| Workload tuning (GPU, args, node) | `Model.spec` (the inline pod spec) | the author's domain; real variation; reviewable |
| Universal engine flags + image | floor (`engine.yaml`) | platform-owned, applies to all, one explicit place |
| EPP routing / flow-control policy | shared standard ConfigMap | infrastructure policy; high/invisible blast radius; same for all |
| EPP container (image/resources) | floor (`epp.yaml`) + optional `epp` container | per-Model sizing; a small open escape hatch |
| The router itself | operator-run, per-Model EPP | platform infrastructure; one EPP + pool per Model |
| Computed values (paths, ZMQ/metrics) | operator-computed, injected | not user-settable; wired into engine and EPP |
| EPP-visible values (KV block size) | floor default + model override | must match the engine; mirrored to the EPP |

In one line each: **the artifact answers "which bytes," the engine answers "how do I run it," the floor answers "the platform's way of running it," the EPP policy answers "how requests reach the replicas," and the computed and EPP-visible values answer "what must stay consistent between engine and EPP."**

## Lifecycle

1. **Resolve** — the operator reads the matching floor entries, the shared EPP policy, the `Model` spec, and the computed and EPP-visible values; it composes the engine config and the EPP config, mirroring the EPP-visible values into the EPP.
2. **Wait on the artifact** — the `Model` is `Pending` until the referenced `ModelArtifact` is `Ready` (weights materialized).
3. **Render children** — the operator creates or updates the engine `Deployment` (sized to `replicas`) + `Service`, the Model's EPP `Deployment`, and the pool (pointing at the engine `Service`).
4. **Ready** — engine replicas are up and serving; the Model's EPP routes to them. Raising `replicas` is picked up automatically by the EPP.
5. **Rollout on change** — re-materializing the artifact, or a floor change, triggers an engine rollout so the new weights or flags are loaded.

## Open items

- **Autoscaling** as a first-class `Model` field: min/max replicas, scale-to-zero, and the scale metric. The natural next step now that scaling is a one-field change.
- **EPP policy per-Model** (today a platform standard) — if a model ever needs non-standard routing, it's a change to the shared standard (or a second standard), not a per-Model field; revisit only if real demand appears.
- **A non-mutating render/dry-run** to preview the composed children before applying, for the floor's fleet-wide blast radius.
- **A single-level named arg-set** in the defaults ConfigMap (e.g. per model family) if per-model parser duplication ever becomes painful — deliberately not built now; the duplication is small and self-describing.
