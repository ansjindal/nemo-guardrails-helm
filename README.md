# nemo-guardrails

A production-oriented Helm chart for the [NVIDIA NeMo Guardrails](https://github.com/NVIDIA-NeMo/Guardrails) API server.

It deploys the guardrails server, renders each guardrails configuration into its own
ConfigMap, and wires provider API keys in through a Secret — so configurations are
managed declaratively instead of being baked into an image.

---

## Contents

- [What gets deployed](#what-gets-deployed)
- [Prerequisites](#prerequisites)
- [Building the image](#building-the-image)
- [Quick start](#quick-start)
- [Guardrails configurations](#guardrails-configurations)
- [Provider API keys](#provider-api-keys)
- [Exposing the API](#exposing-the-api)
- [Values reference](#values-reference)
- [Verifying a deployment](#verifying-a-deployment)
- [Upgrading configurations](#upgrading-configurations)
- [Troubleshooting](#troubleshooting)
- [Uninstalling](#uninstalling)

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

## Building the image

> [!IMPORTANT]
> There is no public registry image for the **NeMo Guardrails library server**. The
> image published on NGC (`nvcr.io/nvidia/nemo-microservices/guardrails`) is the
> separate **NeMo Guardrails microservice**, which exposes a different API surface
> (`/v1/guardrail/...` plus configuration CRUD). This chart targets the open-source
> library server (`/v1/chat/completions`, `/v1/checks`, `/v1/rails/configs`), so you
> build and push that image yourself.

```bash
git clone --depth 1 --branch v0.24.1 https://github.com/NVIDIA-NeMo/Guardrails.git
cd Guardrails
docker build -t <your-registry>/nemoguardrails:0.24.1 .
docker push <your-registry>/nemoguardrails:0.24.1
```

Then point the chart at it:

```yaml
image:
  repository: <your-registry>/nemoguardrails
  tag: "0.24.1"
```

## Quick start

```bash
helm install guardrails ./nemo-guardrails \
  --namespace guardrails --create-namespace \
  --set image.repository=<your-registry>/nemoguardrails \
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
| `image.repository` | `nemoguardrails` | Image repository |
| `image.tag` | `"0.24.1"` | Image tag; falls back to `.Chart.AppVersion` |
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

## License

Apache-2.0. NeMo Guardrails is a trademark of NVIDIA Corporation; this chart is an
independent packaging of the open-source project.
