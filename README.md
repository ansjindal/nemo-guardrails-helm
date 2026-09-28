# nemo-guardrails-helm

[![lint](https://github.com/ansjindal/nemo-guardrails-helm/actions/workflows/lint.yml/badge.svg)](https://github.com/ansjindal/nemo-guardrails-helm/actions/workflows/lint.yml)
[![release](https://github.com/ansjindal/nemo-guardrails-helm/actions/workflows/release.yml/badge.svg)](https://github.com/ansjindal/nemo-guardrails-helm/actions/workflows/release.yml)
[![chart](https://img.shields.io/github/v/release/ansjindal/nemo-guardrails-helm?label=chart&sort=semver&color=0f1689&logo=helm&logoColor=white)](https://github.com/ansjindal/nemo-guardrails-helm/pkgs/container/nemo-guardrails-helm%2Fcharts%2Fnemo-guardrails)
[![image](https://img.shields.io/badge/dynamic/yaml?url=https%3A%2F%2Fraw.githubusercontent.com%2Fansjindal%2Fnemo-guardrails-helm%2Fmain%2FChart.yaml&query=%24.appVersion&label=image&color=2496ed&logo=docker&logoColor=white)](https://github.com/ansjindal/nemo-guardrails-helm/pkgs/container/nemo-guardrails-helm%2Fnemo-guardrails)
[![license](https://img.shields.io/badge/license-Apache--2.0-green.svg)](LICENSE)
[![unofficial](https://img.shields.io/badge/NVIDIA-unofficial-orange.svg)](#container-image)

A production-oriented Helm chart for the [NVIDIA NeMo Guardrails](https://github.com/NVIDIA-NeMo/Guardrails) API server.

It deploys the guardrails server, renders each guardrails configuration into its own
ConfigMap, and wires provider API keys in through a Secret — so configurations are
managed declaratively instead of being baked into an image.

---

## Contents

- [What gets deployed](#what-gets-deployed)
- [Prerequisites](#prerequisites)
- [Container image](#container-image)
- [Quick start](#quick-start)
- [Guardrails configurations](#guardrails-configurations)
- [Adding a model](#adding-a-model)
- [Provider API keys](#provider-api-keys)
- [Tool calling](#tool-calling)
- [Exposing the API](#exposing-the-api)
- [Values reference](#values-reference)
- [Verifying a deployment](#verifying-a-deployment)
- [Upgrading configurations](#upgrading-configurations)
- [Troubleshooting](#troubleshooting)
- [Uninstalling](#uninstalling)
- [Releasing](#releasing)
- [Security scanning](#security-scanning)

---

## What gets deployed

| Resource | Created when | Purpose |
|---|---|---|
| `Deployment` | always | Runs `nemoguardrails server` |
| `Service` | always | ClusterIP on port 8000 |
| `ConfigMap` | one per entry in `guardrailsConfigs` | Holds a configuration's files |
| `Secret` | `modelApiKeys` set and `existingSecret` empty | Upstream provider API keys |
| `ServiceAccount` | `serviceAccount.create` | Pod identity |
| `Ingress` | `ingress.enabled` | External HTTP routing |
| `HorizontalPodAutoscaler` | `autoscaling.enabled` | CPU/memory-based scaling |
| `PodDisruptionBudget` | `podDisruptionBudget.enabled` | Availability during drains |
| Test `Pod` | `helm test` | Probes `/v1/health` and `/v1/rails/configs` |

## Prerequisites

- Kubernetes 1.23+
- Helm 3.8+
- A container image of the NeMo Guardrails server reachable from your cluster

## Container image

This repository builds and publishes the image itself:

```
ghcr.io/ansjindal/nemo-guardrails-helm/nemo-guardrails:<guardrails-version>
```

The image tag always matches the upstream NeMo Guardrails version, which is the chart's
`appVersion`. The chart has its own version, so `helm show chart ... --version <chart>`
tells you which Guardrails release (and image tag) a chart deploys:

| Chart | `appVersion` / image tag |
|---|---|
| `1.0.0` | `0.24.1` |
| `0.24.1` | `0.24.1` (chart versions up to here followed the upstream version) |

> [!IMPORTANT]
> **This is an unofficial build.** NVIDIA does not publish a container image for the
> open-source NeMo Guardrails **library** server. The image on NGC
> (`nvcr.io/nvidia/nemo-microservices/guardrails`) is the separate **NeMo Guardrails
> microservice**, which exposes a different API surface (`/v1/guardrail/...` plus
> configuration CRUD). This chart targets the library server
> (`/v1/chat/completions`, `/v1/checks`, `/v1/rails/configs`), so this repo compiles that
> image from upstream source at the tagged release. It is not supported by NVIDIA.
>
> Provenance is recorded in the image labels:
> ```
> org.opencontainers.image.source  = https://github.com/ansjindal/nemo-guardrails-helm
> org.opencontainers.image.url     = https://github.com/NVIDIA-NeMo/Guardrails
> org.opencontainers.image.vendor  = Unofficial community build
> org.opencontainers.image.licenses = Apache-2.0
> ```

### Building it yourself

If you would rather own the artifact, build from upstream and point the chart at it:

```bash
git clone --depth 1 --branch v0.24.1 https://github.com/NVIDIA-NeMo/Guardrails.git
cd Guardrails
docker build -t <your-registry>/nemoguardrails:0.24.1 .
docker push <your-registry>/nemoguardrails:0.24.1
```

```yaml
image:
  repository: <your-registry>/nemoguardrails
  tag: "0.24.1"
```

## Quick start

From the published chart:

```bash
helm install guardrails \
  oci://ghcr.io/ansjindal/nemo-guardrails-helm/charts/nemo-guardrails --version 1.0.0 \
  --namespace guardrails --create-namespace \
  --set modelApiKeys.OPENAI_API_KEY=sk-... \
  --wait
```

Or from a checkout of this repo:

```bash
helm install guardrails . \
  --namespace guardrails --create-namespace \
  --set modelApiKeys.OPENAI_API_KEY=sk-... \
  --wait
```

Verify:

```bash
helm test guardrails -n guardrails
kubectl port-forward svc/guardrails-nemo-guardrails 8000:8000 -n guardrails
curl http://localhost:8000/v1/rails/configs
```

## Guardrails configurations

The server discovers configurations as **subdirectories** of its config path, where each
directory name is the `config_id`. This chart models that directly: every key under
`guardrailsConfigs` becomes one ConfigMap, mounted at `/config/<key>/`.

Only these configurations are served. The upstream image also bakes example bots into
`/config` (`abc`, `hello_world`, …); the chart masks that directory with an empty volume,
because those examples would otherwise be reachable by `config_id` and would call their
own model endpoints with this pod's provider keys.

```yaml
guardrailsConfigs:
  content-safety:                 # -> config_id "content-safety", mounted at /config/content-safety
    config.yml: |
      models:
        - type: main
          engine: openai
          model: gpt-4o-mini
      rails:
        input:
          flows:
            - self check input
      prompts:
        - task: self_check_input
          content: |
            ...
  tool-calling:                   # -> config_id "tool-calling"
    config.yml: |
      models:
        - type: main
          engine: openai
          model: gpt-4o-mini
      passthrough: true
```

Reference a configuration per request:

```json
{
  "model": "gpt-4o-mini",
  "messages": [{"role": "user", "content": "Hello"}],
  "guardrails": {"config_id": "content-safety"}
}
```

Multi-file configurations work the same way — each key inside a configuration becomes a
file in that directory:

```yaml
guardrailsConfigs:
  advanced:
    config.yml: |
      ...
    rails.co: |
      define user express greeting
        "hello"
    prompts.yml: |
      ...
```

> [!NOTE]
> Helm **merges** maps rather than replacing them, so the bundled `demo` configuration
> stays present unless you explicitly remove it:
> ```bash
> helm install ... --set guardrailsConfigs.demo=null
> ```

## Adding a model

Models are declared **inside a guardrails configuration**, not as a chart-level value.
Every configuration needs at least one entry of `type: main` — the model that answers
requests routed to that `config_id`.

```yaml
guardrailsConfigs:
  my-config:
    config.yml: |
      models:
        - type: main
          engine: openai
          model: gpt-4o-mini
          parameters:
            base_url: https://api.openai.com/v1
```

| Field | Purpose |
|---|---|
| `type` | `main` for the primary model; a named type (e.g. `content_safety`) for a model a rail calls |
| `engine` | Provider integration — selects the client and its default key variable |
| `model` | Model identifier as the provider expects it |
| `parameters` | Passed to the client constructor (`base_url`, `temperature`, `max_tokens`, …) |

> [!IMPORTANT]
> **No API key goes in `config.yml`.** The key is supplied through the environment from a
> Secret — see [Provider API keys](#provider-api-keys). Anything you put under
> `guardrailsConfigs` is rendered into a ConfigMap, which is *not* a secret store.

### Common engines

```yaml
# OpenAI, or any OpenAI-compatible endpoint          -> OPENAI_API_KEY
- type: main
  engine: openai
  model: gpt-4o-mini
  parameters:
    base_url: https://api.openai.com/v1

# NVIDIA NIM, hosted or self-hosted                  -> NVIDIA_API_KEY
- type: main
  engine: nim
  model: meta/llama-3.3-70b-instruct
  parameters:
    base_url: https://integrate.api.nvidia.com/v1

# A NIM running in the same cluster                  -> NVIDIA_API_KEY (often unused)
- type: main
  engine: nim
  model: meta/llama-3.3-70b-instruct
  parameters:
    base_url: http://my-nim.nim.svc.cluster.local:8000/v1
```

### Using a separate model for a rail

Rails can call a dedicated model. Give it a named `type` and reference it with `$model=`:

```yaml
guardrailsConfigs:
  content-safety:
    config.yml: |
      models:
        - type: main
          engine: nim
          model: meta/llama-3.3-70b-instruct
          parameters:
            base_url: http://my-nim.nim.svc.cluster.local:8000/v1

        - type: content_safety
          engine: nim
          model: nvidia/llama-3.1-nemoguard-8b-content-safety
          parameters:
            base_url: http://nemoguard.nim.svc.cluster.local:8000/v1

      rails:
        input:
          flows:
            - content safety check input $model=content_safety
        output:
          flows:
            - content safety check output $model=content_safety
```

### Per-model keys

When models need different credentials, name the variable per model with
`api_key_env_var` and put both keys in the same Secret:

```yaml
models:
  - type: main
    engine: openai
    model: gpt-4o-mini
    api_key_env_var: PRIMARY_MODEL_KEY
  - type: content_safety
    engine: nim
    model: nvidia/llama-3.1-nemoguard-8b-content-safety
    api_key_env_var: SAFETY_MODEL_KEY
```

```yaml
modelApiKeys:
  PRIMARY_MODEL_KEY: sk-...
  SAFETY_MODEL_KEY: nvapi-...
```

## Provider API keys

No credentials are sent to the guardrails server by clients. The server reads a key from
its own environment and uses it for the upstream model call. Resolution order per model
entry is `parameters.api_key` → `api_key_env_var` → the engine's default variable:

| `engine` | Environment variable |
|---|---|
| `openai` | `OPENAI_API_KEY` |
| `nim`, `nvidia_ai_endpoints` | `NVIDIA_API_KEY` |
| `azure`, `azure_openai` | `AZURE_OPENAI_API_KEY` |

Chart-managed Secret (convenient, but the value lands in your release values):

```yaml
modelApiKeys:
  OPENAI_API_KEY: sk-...
```

Externally managed Secret (**recommended for production**) — keys become environment
variables via `envFrom`, so the Secret's keys must be named as above:

```bash
kubectl create secret generic model-keys \
  --from-literal=OPENAI_API_KEY=sk-... -n guardrails
```

```yaml
existingSecret: model-keys
```

## Tool calling

The server accepts the OpenAI `tools`, `tool_choice`, and `parallel_tool_calls`
parameters, but only under two conditions:

1. the configuration sets **`passthrough: true`**, and
2. the request is **non-streaming** (`"stream": false`).

Anything else is rejected with `422` — the parameters are never silently dropped:

```json
{"error":{"message":"The 'tools', 'tool_choice', and 'parallel_tool_calls' parameters are only supported for non-streaming requests when the guardrails configuration has 'passthrough: true'.","type":"invalid_request_error"}}
```

### Configuration

```yaml
guardrailsConfigs:
  tool-calling:
    config.yml: |
      models:
        - type: main
          engine: openai
          model: <tool-calling-capable-model>
          parameters:
            base_url: <your-openai-compatible-model-api>/v1
      passthrough: true
```

### Request

```bash
curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "<tool-calling-capable-model>",
    "messages": [{"role": "user", "content": "What is the weather in San Francisco? Use the get_weather tool."}],
    "tools": [{"type": "function", "function": {
        "name": "get_weather",
        "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}],
    "tool_choice": "auto",
    "guardrails": {"config_id": "tool-calling"}
  }'
```

Tool calls are returned in the standard OpenAI shape, with `finish_reason: "tool_calls"`:

```json
{
  "choices": [{
    "finish_reason": "tool_calls",
    "message": {
      "role": "assistant",
      "tool_calls": [{
        "id": "call-3b96d9d1-a04e-43db-800e-4206998d086d",
        "type": "function",
        "function": {"name": "get_weather", "arguments": "{\"city\": \"San Francisco\"}"}
      }]
    }
  }],
  "guardrails": {"config_id": "tool-calling"}
}
```

Your application executes the tool and sends the result back as a `tool` message on the
next request, as in the standard OpenAI function-calling loop.

> [!WARNING]
> `passthrough: true` sends the prompt to the model unaltered, which **bypasses dialog
> rails**. In the current release you get tool calling *or* the full rails pipeline on a
> given configuration, not both. A common pattern is two configurations — a passthrough
> one for tool-calling turns, and a rails-enabled one for conversational turns — with the
> application choosing `config_id` per request.

### Known limitations

| Limitation | Upstream |
|---|---|
| Streaming (`stream: true`) with `tools` returns 422 | [NVIDIA-NeMo/Guardrails#2056](https://github.com/NVIDIA-NeMo/Guardrails/issues/2056) |
| Non-passthrough configurations cannot use `tools` | [NVIDIA-NeMo/Guardrails#2057](https://github.com/NVIDIA-NeMo/Guardrails/issues/2057) |

## Exposing the API

```yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
  hosts:
    - host: guardrails.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: guardrails-tls
      hosts:
        - guardrails.example.com
```

The long read timeout matters: guarded completions run extra LLM calls for input and
output rails, so they take longer than a bare model call. Streaming responses hold the
connection open for the duration of the generation.

## Values reference

### Image and workload

| Key | Default | Description |
|---|---|---|
| `replicaCount` | `1` | Replicas when autoscaling is disabled |
| `image.repository` | `ghcr.io/ansjindal/nemo-guardrails-helm/nemo-guardrails` | Image repository |
| `image.tag` | `""` | Image tag; empty resolves to `.Chart.AppVersion` |
| `image.pullPolicy` | `IfNotPresent` | Pull policy |
| `imagePullSecrets` | `[]` | Registry credentials |
| `resources` | 250m/512Mi → 2/2Gi | Requests and limits |

### Server

| Key | Default | Description |
|---|---|---|
| `server.port` | `8000` | Listen port |
| `server.configPath` | `/config` | Config mount root |
| `server.disableChatUi` | `true` | Disable the bundled Chainlit UI |
| `server.verbose` | `false` | Verbose logs, including rendered prompts |
| `server.autoReload` | `false` | Reload a config when its files change |
| `server.defaultConfigId` | `""` | Config used when a request omits `config_id` |
| `server.extraArgs` | `[]` | Extra CLI flags |

### Configuration and credentials

| Key | Default | Description |
|---|---|---|
| `guardrailsConfigs` | one `demo` config | Map of `config_id` → files |
| `modelApiKeys` | `{}` | Keys rendered into a chart-managed Secret |
| `existingSecret` | `""` | Pre-existing Secret; overrides `modelApiKeys` |
| `extraEnv` | `[]` | Additional plain environment variables |

### Networking

| Key | Default | Description |
|---|---|---|
| `service.type` | `ClusterIP` | Service type |
| `service.port` | `8000` | Service port |
| `ingress.enabled` | `false` | Create an Ingress |

### Scaling and scheduling

| Key | Default | Description |
|---|---|---|
| `autoscaling.enabled` | `false` | Create an HPA |
| `autoscaling.minReplicas` / `maxReplicas` | `1` / `5` | HPA bounds |
| `podDisruptionBudget.enabled` | `false` | Create a PDB |
| `nodeSelector`, `tolerations`, `affinity` | `{}` / `[]` | Scheduling controls |
| `topologySpreadConstraints` | `[]` | Spread replicas across nodes |

### Health and security

| Key | Default | Description |
|---|---|---|
| `probes.startup.failureThreshold` | `30` | Allows ~5 min for first boot |
| `probes.liveness.*`, `probes.readiness.*` | see `values.yaml` | Probe tuning |
| `podSecurityContext` | non-root UID `10001`, `RuntimeDefault` seccomp | Pod-level security context |
| `securityContext` | read-only root FS, no privilege escalation, drops all caps | Container-level security context |
| `scratch.mountPath` / `scratch.sizeLimit` | `/scratch` / `256Mi` | Writable emptyDir used as `HOME`, `TMPDIR`, and the Chainlit working directory |
| `embeddingModelCache` | `/tmp/fastembed_cache` | Where the image keeps its pre-downloaded embedding model |

The pod meets the Kubernetes *restricted* Pod Security Standard. The upstream image is
built as root, but its files are world-readable, so it runs unchanged as an arbitrary UID;
the only writes (Chainlit's working files, temp files) go to the `scratch` volume. If you
mount extra volumes the server must write to, give them an `emptyDir` or a writable PVC —
the root filesystem stays read-only.

## Verifying a deployment

`helm test` runs a pod that checks liveness and config discovery:

```bash
helm test <release> -n <namespace>
```

The test pod is deleted when it passes, so `--logs` cannot fetch its output and exits
non-zero; on failure the pod is kept, and `kubectl logs <release>-nemo-guardrails-test-connection`
shows why.

Manual end-to-end check:

```bash
kubectl port-forward svc/<release>-nemo-guardrails 8000:8000 -n <namespace>

curl http://localhost:8000/v1/health
curl http://localhost:8000/v1/rails/configs

curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "<model-id>",
    "messages": [{"role": "user", "content": "Hello!"}],
    "guardrails": {"config_id": "demo"}
  }'
```

## Upgrading configurations

The Deployment carries a `checksum/config` annotation over the rendered ConfigMaps, so
editing a configuration and running `helm upgrade` rolls the pods automatically — no
manual restart:

```bash
helm upgrade <release> ./nemo-guardrails -f my-values.yaml -n <namespace>
```

Set `server.autoReload=true` to have the server pick up file changes in place instead.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Pod stuck `ContainerCreating` | A referenced `existingSecret` does not exist |
| `CrashLoopBackOff` at startup | Malformed YAML in a `guardrailsConfigs` entry; check `kubectl logs` |
| `/v1/rails/configs` returns `[]` | No configuration mounted, or `server.configPath` overridden without matching mounts |
| Requests return 401/403 from the provider | Missing or wrong key; confirm the variable name matches the engine |
| Startup probe failing | First boot loads the embedding model; raise `probes.startup.failureThreshold` |
| 422 on `tools` requests | The server only accepts `tools` for non-streaming requests on a config with `passthrough: true` |
| `Read-only file system` in the logs | Something writes outside `/scratch`; point it there with `extraEnv`, or mount a writable volume at that path |

Inspect what the server actually loaded:

```bash
kubectl exec -n <namespace> deploy/<release>-nemo-guardrails -- ls -R /config
kubectl logs -n <namespace> deploy/<release>-nemo-guardrails
```

## Uninstalling

```bash
helm uninstall <release> -n <namespace>
```

ConfigMaps and the chart-managed Secret are removed with the release. A Secret referenced
via `existingSecret` is left in place.

## Releasing

`.github/workflows/release.yml` builds the image and publishes the chart in one run.
`Chart.yaml` holds both versions:

```
version     the chart's own SemVer — bump it for any chart change
appVersion  upstream Guardrails version == image tag
```

Artifacts publish under the repository path, so both auto-link to this repo:

```
image  ghcr.io/ansjindal/nemo-guardrails-helm/nemo-guardrails:<appVersion>
chart  ghcr.io/ansjindal/nemo-guardrails-helm/charts/nemo-guardrails:<version>
```

To release, bump `version` in `Chart.yaml` (and `appVersion` when moving to a new
upstream release), merge, then push the matching tag:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

The run fails if the tag does not match `Chart.yaml`, or if that chart version is already
published — a published chart version is never overwritten. The image tag is rebuilt on
every release, which picks up base-image security fixes; pin the image by digest if you
need it immutable.

Or run **Actions → release → Run workflow**, which releases the versions in `Chart.yaml`
on the selected branch. Leave `publish` unchecked for a dry run that builds, scans, and
tests without pushing anything.

The run does three things in order:

1. **resolve** — reads both versions from `Chart.yaml`, validates them as SemVer, and
   checks the tag and that the chart version is unpublished.
2. **image** — checks out `NVIDIA-NeMo/Guardrails` at `v<appVersion>` and builds the image
   with layer caching into the local Docker daemon. It then scans the image with Trivy
   (report, SBOM, code scanning upload), installs the chart into a kind cluster with that
   exact image and runs `helm test`, and enforces the vulnerability policy. Only then does
   it push `:<appVersion>` and `:latest` to GHCR — the pushed image is the one that was
   scanned and tested, not a rebuild.
3. **chart** — lints, scans the chart for misconfigurations, packages it, asserts the rendered
   Deployment references the exact image tag just published, pushes the chart to
   `oci://ghcr.io/<owner>/<repo>/charts`, and creates a GitHub release with the `.tgz`,
   the CycloneDX SBOM, and the full Trivy report attached.

Because `image.tag` defaults to empty, the chart resolves its image from `appVersion` —
the two cannot drift.

> [!NOTE]
> GHCR packages are **private** on first publish. After the initial release, set both the
> image and chart packages to public under the repository's package settings, otherwise
> `helm install` from the OCI URL will fail with an authorization error. Repo linking is
> automatic via `org.opencontainers.image.source`.

### Targeting a different registry

Override the `env` block at the top of the workflow:

```yaml
env:
  REGISTRY: nvcr.io
  IMAGE_NAME: nemo-guardrails
```

Non-GHCR registries also need their own login step and credentials in repository secrets.

## Security scanning

[Trivy](https://github.com/aquasecurity/trivy) checks both artifacts, at three points:

| Workflow | When | What | Fails on |
|---|---|---|---|
| `lint-and-template` | every PR and push to `main` | Chart misconfigurations (`trivy config`); install into kind + `helm test` | HIGH/CRITICAL misconfiguration; failed install or test |
| `release` | every release, before anything is pushed | Image CVEs (OS and Python packages), SBOM; chart misconfigurations; kind install + `helm test` with the new image | Fixable HIGH/CRITICAL CVE; HIGH/CRITICAL misconfiguration; failed install or test |
| `security-scan` | daily, and on demand | CVEs in every image the latest release deploys (server and `helm test` images) | Fixable HIGH/CRITICAL CVE |

- **Where findings appear:** Security → Code scanning, categorised by `image`,
  `image:<ref>`, and `chart-misconfig`. Image uploads are limited to HIGH/CRITICAL to keep
  the tab actionable; the full report and a CycloneDX SBOM are attached to every release.
- **Why "fixable" only:** most Debian findings in the image have no fixed package yet
  (many are `linux-libc-dev` kernel headers that the upstream Dockerfile's build toolchain
  leaves in the runtime image and that a container never uses). Gating on them would
  block every release without offering a remedy; they stay visible in the report.
- **Accepting a finding:** add it to [`.trivyignore.yaml`](.trivyignore.yaml) with a
  `statement` explaining why and an `expired_at` date. Only the gates read that file;
  reports still show the finding, and it fails the gate again once it expires.

Run the same checks locally:

```bash
# Chart
trivy config --ignorefile .trivyignore.yaml --severity HIGH,CRITICAL .

# Image — the gate as CI runs it
trivy image --scanners vuln --ignore-unfixed --severity HIGH,CRITICAL \
  --ignorefile .trivyignore.yaml \
  ghcr.io/ansjindal/nemo-guardrails-helm/nemo-guardrails:<guardrails-version>
```

> [!IMPORTANT]
> Trivy's own distribution was
> [compromised in March 2026](https://github.com/advisories/GHSA-69fq-xp46-6x23) through
> mutable tags. Every action in these workflows is pinned to a full commit SHA, and the
> Trivy binary to an explicit version (`v0.74.0`). Dependabot proposes SHA bumps weekly;
> bump the Trivy version deliberately, after checking the release against Aqua's
> advisories, in all four places it appears.

## License

Apache-2.0. NeMo Guardrails is a trademark of NVIDIA Corporation; this chart is an
independent packaging of the open-source project.
