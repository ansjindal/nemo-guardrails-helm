# nemo-guardrails-helm

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
ghcr.io/ansjindal/nemo-guardrails:<version>
```

The tag always matches the upstream NeMo Guardrails version and the chart version, so
`helm install --version 0.24.1` and image tag `0.24.1` always correspond.

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
> org.opencontainers.image.source  = https://github.com/NVIDIA-NeMo/Guardrails
> org.opencontainers.image.url     = https://github.com/ansjindal/nemo-guardrails-helm
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
  oci://ghcr.io/ansjindal/charts/nemo-guardrails --version 0.24.1 \
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
| `image.repository` | `ghcr.io/ansjindal/nemo-guardrails` | Image repository |
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
| `podSecurityContext` | `{}` | Pod-level security context |
| `securityContext` | drops all caps | Container-level security context |

> [!WARNING]
> The upstream image installs its Python environment and embedding-model cache as root,
> so `runAsNonRoot` is **not** enabled by default. Rebuild the image with a dedicated UID
> before hardening this further.

## Verifying a deployment

`helm test` runs a pod that checks liveness and config discovery:

```bash
helm test <release> -n <namespace> --logs
```

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

`.github/workflows/release.yml` builds the image and publishes the chart in one run, so a
release is a single version number applied consistently:

```
chart version == appVersion == image tag == upstream Guardrails version
```

Trigger by pushing a tag:

```bash
git tag v0.24.1 && git push origin v0.24.1
```

Or run **Actions → release → Run workflow**, supplying the upstream version. Leave
`publish` unchecked for a dry run that builds and packages without pushing anything.

The run does three things in order:

1. **resolve** — derives the version, validates it as SemVer.
2. **image** — checks out `NVIDIA-NeMo/Guardrails` at `v<version>`, builds the image with
   layer caching, and pushes `:<version>` and `:latest` to GHCR.
3. **chart** — lints, packages with `--version`/`--app-version` set to the release
   version, asserts the rendered Deployment references the exact image tag just
   published, pushes the chart to `oci://ghcr.io/<owner>/charts`, and creates a GitHub
   release with the `.tgz` attached.

Because `image.tag` defaults to empty, the chart resolves its image from `appVersion` —
the two cannot drift.

> [!NOTE]
> GHCR packages are **private** on first publish. After the initial release, set both the
> image and chart packages to public under the repository's package settings, otherwise
> `helm install` from the OCI URL will fail with an authorization error.

### Targeting a different registry

Override the `env` block at the top of the workflow:

```yaml
env:
  REGISTRY: nvcr.io
  IMAGE_NAMESPACE: your-org
  IMAGE_NAME: nemo-guardrails
```

Non-GHCR registries also need their own login step and credentials in repository secrets.

## License

Apache-2.0. NeMo Guardrails is a trademark of NVIDIA Corporation; this chart is an
independent packaging of the open-source project.
