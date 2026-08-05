# KubeArmor Zero-Trust Policy

A default-deny process policy for the Wisecow workload deployed in PS1, verified under real AppArmor enforcement.
 
**Artifacts:** `wisecow-zero-trust.yaml`, screenshots in `../docs/screenshots/`.

--
 
## What makes it zero-trust
 
The policy's `process` block uses `action: Allow`. In KubeArmor, the presence of a single Allow rule for a category inverts that category to default-deny — the listed binaries are permitted and **everything else is blocked automatically**. The whitelist is the mechanism; the inversion is the posture. A policy built from `action: Block` rules would be a blocklist, which is the opposite approach.
 
---

## Building the whitelist
 
Reading `wisecow.sh` yields eight binaries: `bash`, `nc`, `cat`, `sleep`, `rm`, `mkfifo`, `fortune`, `cowsay`.
 
That list is incomplete, and enforcement is what proved it. Each of the following was found by a `CrashLoopBackOff` followed by a `karmor logs` line naming the denial:
 
| Path | Why it wasn't obvious |
|---|---|
| `/usr/bin/env` | The shebang is `#!/usr/bin/env bash`, so `env` executes before bash does. It appears nowhere in the script body. |
| `/usr/bin/perl` | `cowsay` is a Perl script. Executing it spawns the interpreter as a separate process, which the LSM evaluates independently. |
| `/usr/bin/nc.openbsd` | `/usr/bin/nc` is a symlink. AppArmor matches the **resolved** binary, so whitelisting the symlink path has no effect. |
| `/app/wisecow.sh` | The kernel execs the script path itself before handing control to the interpreter. Whitelisting interpreters is not sufficient. |
 
Static analysis of the source produced a policy that looked correct and would have killed the workload. The dependency graph was only fully visible at runtime.
 
---

## The file posture trade-off
 
Setting `kubearmor-file-posture=block` on the namespace makes file access default-deny. Under that posture the container could not start: `bash: ./wisecow.sh: Permission denied` — bash was denied read access to its own script.
 
A file whitelist permissive enough to run the workload would need to cover everything bash, perl, and fortune touch, which in practice means allowing `/` recursively. That is not a meaningful constraint.
 
The policy therefore scopes deliberately:
 
- **Process** — strict whitelist, default-deny. This is the zero-trust demonstration.
- **File** — targeted `action: Block` rules on `/etc/passwd` and `/etc/shadow`. Explicit Block rules enforce regardless of default posture, giving a demonstrable denial without breaking the workload.
A production hardening effort would extend the file rules incrementally from observed behaviour rather than starting from default-deny.
 
---

## Environment
 
KubeArmor enforces through a host LSM. Where none is available it degrades to audit — violations are detected and logged, but not blocked.
 
| Environment | Active LSM | Container Security | Result |
|---|---|---|---|
| WSL2 (kernel 6.6-microsoft-standard) | none | `false` | Audit only — alerts attributed to `DefaultPosture` |
| Kind on Ubuntu 24.04 | none | `false` | Audit only — the Debian node container does not expose the host LSM to workloads inside it |
| **k3s on Ubuntu 24.04** | **AppArmor** | **`true`** | **Enforcing** |
 
k3s runs against the host kernel with no nested container layer, which is why it works where Kind does not. The policy YAML is identical across all three; only the enforcement outcome differs.
 
---

## Reproducing
 
```bash
# Prerequisites: a cluster on a host with AppArmor or BPF-LSM active
cat /sys/kernel/security/lsm      # must contain apparmor or bpf
 
helm repo add kubearmor https://kubearmor.github.io/charts
helm repo update kubearmor
helm upgrade --install kubearmor-operator kubearmor/kubearmor-operator \
  -n kubearmor --create-namespace
kubectl apply -f https://raw.githubusercontent.com/kubearmor/KubeArmor/main/pkg/KubeArmorOperator/config/samples/sample-config.yml
 
karmor probe                       # expect Container Security: true
 
kubectl apply -f kubearmor/wisecow-zero-trust.yaml
kubectl rollout restart deployment/wisecow -n wisecow
```
 
Pods must be restarted after installing KubeArmor — the armoring annotation is applied at admission, so pods that predate the install are never armored.
 
**Verify the workload still runs** (a complete whitelist should not break it):
 
```bash
kubectl port-forward -n wisecow svc/wisecow-service 8080:80 &
sleep 3 && curl http://localhost:8080
```
 
**Trigger a violation:**
 
```bash
# terminal 1
karmor logs --logFilter=policy -n wisecow
 
# terminal 2
kubectl exec -n wisecow deploy/wisecow -- cat /etc/passwd
```
 
Expected: `cat: /etc/passwd: Permission denied`, exit code 1, and an alert carrying `PolicyName: wisecow-zero-trust`, `Action: Block`, `Result: Permission denied`, `Enforcer: AppArmor`.
 
---

## Evidence
 
| Screenshot | Shows |
|---|---|
| `kubearmor-probe.png` | `Active LSM: AppArmor`, `Container Security: true`, Wisecow pods armored with `wisecow-zero-trust` |
| `kubearmor-policy-violation.png` | Blocked `/etc/passwd` read — command refused with exit 1, alert attributed to the policy |
| `kubearmor-audit-wsl.png` | Audit-mode, `Active LSM: ` Blank |