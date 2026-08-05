# Wisecow on Kubernetes
Containerised deployment of the Wisecow application on a Kind cluster, with TLS termination at the ingress, an automated build/push pieline to GHCR and two complementary continuous deployment paths.

## Prerequisites

```
sudo apt install fortune-mod cowsay -y
```

## What Wisecow actually is
`wisecow.sh` = a hand-rolled HTTP server built from `netcat` and a named pipe: 

```
cat $RSPFILE | nc -lN $SRVPORT | handleRequest
```

`nc` listens on :4499; an incoming request is piped into `handleRequest`, which runs `fortune | cowsay` and writes a hand-assembled HTTP response into a FIFO; `cat` feeds that FIFO back into netcat's stdin. `-N` closes the connection after EOF, then the loop restarts.

# Problem Statement
Deploy the wisecow application as a k8s app

## Requirement
1. Create Dockerfile for the image and corresponding k8s manifest to deploy in k8s env. The wisecow service should be exposed as k8s service.
2. Github action for creating new image when changes are made to this repo
3. [Challenge goal]: Enable secure TLS communication for the wisecow app.

## Expected Artifacts
1. Github repo containing the app with corresponding dockerfile, k8s manifest, any other artifacts needed.
2. Github repo with corresponding github action.
3. Github repo should be kept private and the access should be enabled for following github IDs: nyrahul

## Architecture

```
Browser ──HTTPS──> ingress-nginx ──HTTP──> Service (ClusterIP :80) ──> Pods (:4499)
                   [TLS terminates here]                               [plain HTTP]
```

TLS is terminated at the edge and traffic runs plaintext inside the cluster. This is both a necessity here (the app is netcat) adn the conventional production pattern.

---

## Repository layout

```
.
├── wisecow.sh                     # application
├── Dockerfile
├── .dockerignore
├── kind-config.yaml               # host port mappings 80/443 + ingress-ready label
├── k8s/
│   ├── namespace.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── ingress.yaml
├── argocd/
│   └── application.yaml
├── .github/workflows/
│   └── build.yaml                 # build + push + deploy
└── docs/screenshots/
```

---

## Running it locally
 
**Prerequisites:** Docker, `kind`, `kubectl`, `openssl`.
 
```bash
# 1. Cluster creation
kind create cluster --name wisecow --config kind-config.yaml
 
# 2. Ingress controller (the Kind-specific variant)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=180s
 
# 3. Application
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/deployment.yaml -f k8s/service.yaml
 
# 4. TLS certificate - excluded from repo w/ .gitignore file
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt \
  -subj "/CN=wisecow.local/O=wisecow" \
  -addext "subjectAltName=DNS:wisecow.local"
kubectl create secret tls wisecow-tls --cert=tls.crt --key=tls.key -n wisecow
 
# 5. Ingress
kubectl apply -f k8s/ingress.yaml
echo "127.0.0.1 wisecow.local" | sudo tee -a /etc/hosts
 
# 6. Verify
curl -k https://wisecow.local
```
 
`--resolve` avoids the hosts-file dependency entirely, which is how CI verifies the endpoint:
 
```bash
curl -k --resolve wisecow.local:443:127.0.0.1 https://wisecow.local
```
 
---

## CI/CD
 
### Build and push
 
On every push to `main`, the workflow builds the image and pushes it to GHCR tagged with both the full commit SHA and `latest`. I chose GHCR over Docker Hub because authentication uses the auto provisioned `GITHUB_TOKEN` ( therefore no need for external secrets to manage). Layer caching via `type=gha` keeps rebuilds at roughly 15s.
 
The SHA tag is the one that matters: pinning an immutable reference is what actually triggers a rollout. Reapplying a manifest that says `:latest` is a no-op as far as Kubernetes is concerned.
 
### Continuous deployment
 
Two approaches are implemented, because they answer the same constraint differently.
 
**The constraint:** GitHub's hosted runners cannot reach a Kind cluster running on a laptop behind NAT.
 
**1. Ephemeral cluster in CI** (`deploy-to-kind` job). The workflow stands up a throwaway Kind cluster, side-loads the freshly built image, applies the manifests, pins the SHA tag via `kubectl set image`, installs ingress-nginx, provisions a certificate and verifies the HTTPS endpoint end-to-end before tearing everything down. This produces a reproducible, publicly inspectable proof that the manifests deploy and serve correctly.
 
**2. ArgoCD pull-based GitOps** (`argocd/application.yaml`). ArgoCD runs inside the cluster and reconciles against the repository, so the connection is outbound-only and the NAT problem disappears. `selfHeal: true` means drift is corrected automatically — scaling the deployment to 1 replica by hand results in ArgoCD detecting `OutOfSync` and restoring the declared state.
 
The first proves the artifacts work; the second is the pattern that scales to real environments.
 
---

## Design notes
 
Decisions that are non-obvious from reading the YAML.
 
**`PATH` must include `/usr/games`.** On Debian/Ubuntu, apt installs `fortune` and `cowsay` there, and it is not on the default container `PATH`. Without the `ENV PATH` line, `prerequisites()` fails and the container exits 1 despite the packages being installed correctly.
 
**`netcat-openbsd` specifically.** The script uses `nc -lN`; the `-N` flag does not exist in BusyBox or traditional netcat.
 
**`/app` is chowned to the non-root user.** The script runs `mkfifo response` in its working directory at startup. Files land root-owned by default, so without the `chown` the FIFO cannot be created and the server never serves.
 
**Probes are `tcpSocket`, not `httpGet`.** The application's response omits the blank line separating headers from body, which the kubelet's HTTP client rejects. Since a failing liveness probe restarts the container, `httpGet` produces a CrashLoopBackOff that looks like an application bug but is not. A secondary reason: the server handles one connection at a time, so cheap connect-and-close probes avoid competing with real traffic.
 
**`readOnlyRootFilesystem` is intentionally absent.** The FIFO creation requires a writable working directory. Achieving a read-only root would require mounting an `emptyDir` over `/app`, which conflicts with the copied script. Every other hardening control is applied: `runAsNonRoot`, `allowPrivilegeEscalation: false`, all capabilities dropped.
 
**`proxy-buffering: "off"` on the Ingress.** nginx buffering in front of a connection-per-request server that closes immediately after writing can produce empty replies.
 
**The TLS Secret is not in the repository.** A `kubernetes.io/tls` Secret contains a base64-encoded private key. It is created imperatively and `tls.key`/`tls.crt` are gitignored. In production this would be issued by cert-manager or an external secrets operator rather than being a manual step.
 
**`argocd/application.yaml` sits outside `k8s/`.** The Application points at `path: k8s` and syncs everything there. Placing the Application inside that directory would make ArgoCD attempt to apply its own definition into the `wisecow` namespace, leaving it permanently `OutOfSync`.
 
**`terminationGracePeriodSeconds: 15`.** Bash as PID 1 does not forward `SIGTERM` into the `while` loop, so pods run out the full grace period before being killed. Shortened from the default 30s to keep rollouts responsive.
 
**`:latest` in the committed manifest is a known limitation.** ArgoCD compares git against live state, and a tag that never changes in git will always report `Synced` regardless of the image actually running. The production form of this is CI committing the SHA tag back into the manifest so sync status reflects reality.
 
---

## Evidence
 
See `docs/screenshots/`:
 
| Screenshot | Shows |
|---|---|
| `TLS-handshake.png` | CI job: TLS handshake, cow served over HTTPS |
| `argocd-wisecow-resource-tree.png` | ArgoCD resource tree, Synced / Healthy |
| `ArgoCD-self-healing-tested.png` | Manual scale to 1 replica detected and reverted |
 
---

## Upstream
 
Application source: [nyrahul/wisecow](https://github.com/nyrahul/wisecow). All containerisation, manifests, pipeline, and TLS configuration in this repository are original work.

---

## Other problem statements

- **PS2 — Scripting:** [`scripts/`](scripts/) — system health monitor (Python) and application health checker (Bash), with usage and exit-code documentation.
- **PS3 — KubeArmor:** [`kubearmor/`](kubearmor/) — zero-trust policy, enforcement evidence, and notes on building the process whitelist.