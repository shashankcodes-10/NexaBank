# Deploy NexaBank to EKS

> This file is the runbook: what to run, in what order, and how to know it worked.
> If you only want the short version, jump to **section 8** and let `scripts/deploy.sh` do the work.

About 60 minutes, ~20 of them `terraform apply` waiting for EKS. Roughly **$8-9/day** while it is up
(EKS control plane, 2× t3.large, one NAT gateway, one NLB, EBS volumes, the EC2 machine). Check the AWS
pricing page for your region. Section 13 tears everything down.

```
you ──▶ launch one EC2 machine by hand ──ansible──▶ tools installed
on that EC2 machine:
  terraform/bootstrap   ─▶ S3 bucket for Terraform state
  terraform/            ─▶ VPC · EKS · gp3 · Pod Identity · Secrets Manager (empty) · ArgoCD
  scripts/set-secrets.sh─▶ YOUR passwords into Secrets Manager
  scripts/deploy.sh     ─▶ Envoy Gateway (AWS NLB) · platform app-of-apps · NexaBank
  browser               ─▶ http(s)://<load balancer or your domain>
```

What runs where:

| Layer | Installed by | Contents |
| --- | --- | --- |
| Cloud | Terraform | VPC, EKS, EBS CSI + gp3, Pod Identity roles, secret containers, ArgoCD |
| Gateway | `deploy.sh` (Helm) | Envoy Gateway → creates the AWS load balancer |
| Platform | ArgoCD, `gitops/argocd/platform/` | External Secrets, cert-manager, Prometheus, Grafana, node-exporter, Loki, Promtail, Tempo, OpenTelemetry Collector |
| App | ArgoCD, `gitops/argocd/nexabank-raw.yaml` (default) or `nexabank-helm.yaml` | App, MySQL, Ollama, HPA, Gateway/routes: from plain manifests in `k8s/` or the Helm chart in `helm/nexabank` (same result, see below) |

Platform apps arrive in **sync waves**:

| Wave | What |
| --- | --- |
| 0 | External Secrets Operator, cert-manager |
| 1 | ClusterSecretStore + Grafana secret, ClusterIssuers, Prometheus (+Grafana, node-exporter), Loki, Tempo |
| 2 | Promtail, OpenTelemetry Collector |
| 4 | alert rules |

## Repo layout

```
ansible/              EC2 machine setup (01 tools, 02 aws, 03 clone, 04 verify, site.yml)
terraform/bootstrap/  the state bucket (local state)
terraform/            the cluster (state in S3)
gitops/argocd/        platform.yaml (app-of-apps), nexabank-raw.yaml, nexabank-helm.yaml, platform/*.yaml (one per component)
gitops/gateway/       GatewayClass + EnvoyProxy (NLB)
gitops/cert-manager/  Let's Encrypt issuers
gitops/external-secrets/  ClusterSecretStore + Grafana ExternalSecret
gitops/observability/ Helm values for every observability tool + alert rules
k8s/                  the application as plain manifests (app/, gateway-http/, gateway-https/)
helm/nexabank/        the same application as a Helm chart
scripts/              configure.sh · set-secrets.sh · deploy.sh · destroy.sh
.github/workflows/    CI (devsecops, docker push, bump, terraform-ci ...)
```

---

## 0. Before you start

**On your laptop:** an AWS account with admin rights, the AWS CLI (`aws configure`), Terraform ≥ 1.11
(needed for S3-native state locking), Ansible (`pip install ansible`), `git`, and an EC2 **key pair**
in your region (EC2 console → Key Pairs → create, save the `.pem`, `chmod 400` it).

**Your Git repo:** this repo must be on GitHub under an account you can push to, public (or give ArgoCD
credentials), on a branch called `main` (or run `configure.sh --branch`).
**Your image:** CI pushes `<dockerhub-user>/nexabank:sha-<7>`; set `image.repository` in
`k8s/app/nexabank-deployment.yaml` (raw mode) or `helm/nexabank/values.yaml` (Helm mode) to yours; CI keeps both in step. The Docker Hub repo must be public (or add an image pull secret).

**Region:** default is `ap-south-1`. Changing it touches five places; `scripts/configure.sh --region`
does four of them (`terraform.tfvars`, secret store, Ansible; you do `aws configure set region` and the bootstrap
`-var=region=`).

---

## 1. Launch the EC2 machine (by hand)

One small machine does all the work: it runs Ansible's tools, Terraform and kubectl. Create it in the
EC2 console (or CLI) in the **same region** as the cluster:

| Setting | Value |
| --- | --- |
| AMI | Ubuntu Server 24.04 LTS (x86_64). The playbooks expect Ubuntu and the `ubuntu` user |
| Type | `t3.small` is plenty (nothing heavy runs on it) |
| Key pair | an existing one, or create one and keep the `.pem` (`chmod 400`) |
| Network | default VPC, public subnet, auto-assign public IP **on** |
| Security group | inbound SSH (22) from **My IP** only. Never 0.0.0.0/0 |
| Storage | 20 GiB gp3 |
| AWS access | an IAM role on the instance **or** an IAM user's access keys, see below |

**The machine needs AWS permissions, by one of two routes.** Terraform creates the VPC, EKS, IAM roles, an S3 bucket
and Secrets Manager secrets from here, so whatever identity it uses must be allowed to do that (for learning,
`AdministratorAccess`; for anything shared, a scoped policy covering EC2, EKS, IAM, S3, Secrets Manager, ELB, Auto Scaling, KMS, CloudWatch Logs).

| | A. IAM user + access keys (what devboard does) | B. IAM role on the instance |
| --- | --- | --- |
| Setup | Create an IAM user, make an access key, run `aws configure` on the machine | Create a role, attach it to the instance (EC2 → Actions → Security → Modify IAM role) |
| Credentials | Long-lived keys stored in `~/.aws/credentials` | Short-lived, rotated automatically, nothing stored |
| Risk | If the machine or the keys leak, they work from anywhere until you delete them | Only usable from that instance |
| Good for | Learning, quick start | Anything you will keep running; safer default |

Either works with every script here. With keys: run `aws configure` on the machine (region `ap-south-1`) and
leave `aws_access_key` empty in `ansible/group_vars/nexabank.yml`, so no key ever sits in a file in Git.
Delete or deactivate the access key when you are finished. With a role: leave `aws_access_key` empty too; the AWS CLI finds the role.

**You know it worked when** you can `ssh -i ~/.ssh/<key>.pem ubuntu@<public-ip>`.

> Run **everything from here on on this machine, with the same AWS identity**. EKS makes whoever runs `terraform apply`
> (the IAM user or the role) the cluster admin. If you later switch identity, `kubectl` stops working.

## 2. Install the tools with Ansible

```bash
cd ansible
vi inventory.ini              # your EC2 machine (or keep `localhost` and run Ansible on the machine itself)
vi group_vars/nexabank.yml    # repo_url -> your repo (leave the AWS keys empty: the role is used)
ansible-playbook -i inventory.ini site.yml
```

Installs AWS CLI v2, Terraform, kubectl, Helm, gh, jq, dig, git, then clones the repo to `~/NexaBank`
and verifies everything. **You know it worked when** `04-verify` prints a version for every tool, says
`Terraform ... is fine` and `Logged in to AWS as arn:aws:...` (your IAM user, or `assumed-role/<your role>` if you used a role).

## 3. Log in and configure the repo

```bash
ssh -i ~/.ssh/<key>.pem ubuntu@<ec2-ip>
cd NexaBank
gh auth login && git config --global user.name "You" && git config --global user.email "you@example.com"

./scripts/configure.sh --repo <your-github-user>/NexaBank          # + --region / --domain / --email if needed
terraform fmt -recursive terraform                                 # once, so terraform-ci stays green
git add -A && git commit -m "configure for my environment" && git push -u origin main
```

`configure.sh` rewrites every `repoURL`/`targetRevision` in `gitops/argocd/`, the Ansible repo URL, and
(optionally) region, Let's Encrypt email and domain. ArgoCD syncs from whatever `repoURL` says: if it
still points elsewhere your pushes never reach the cluster (the single most common problem; `deploy.sh`
refuses to run in that state).

## 4. Create the state bucket

```bash
cd terraform/bootstrap
terraform init
terraform apply                      # yes
terraform output -raw backend_hcl > ../backend.hcl
cd .. && terraform init -backend-config=backend.hcl
```

**You know it worked when** you see `Successfully configured the backend "s3"`.
`backend.hcl` is git-ignored (it names *your* bucket). Commit `terraform/.terraform.lock.hcl` so provider versions are pinned.

## 5. Build the cluster

```bash
terraform plan                       # ~70 resources
terraform apply                      # 15-20 minutes
$(terraform output -raw configure_kubectl)
```

**You know it worked when:**

```bash
kubectl get nodes                                    # 2 Ready
kubectl get storageclass                             # gp3 (default)
kubectl -n kube-system get pods | grep -E 'ebs-csi|metrics-server|pod-identity'
kubectl -n argocd get pods                           # Terraform installed ArgoCD too
```

> Terraform created the Secrets Manager secrets' **names**, not their **values**: that is step 6.
> If the first apply fails with a Kubernetes/Helm provider connection error, re-run `terraform apply`.

## 6. Set YOUR passwords

```bash
cd ~/NexaBank
./scripts/set-secrets.sh
```

It asks for each value (typing is hidden) and stores them in AWS Secrets Manager. They never touch Git
or Terraform state. External Secrets Operator turns them into Kubernetes Secrets later.

| Prompt | Used for |
| --- | --- |
| MySQL root password | MySQL `root` |
| MySQL app username (default `nexabank`) and password | what the app connects with |
| Grafana admin password | login to Grafana (user `admin`) |

Any characters are fine. Pick strong, different passwords. No script? Same thing by hand:

```bash
aws secretsmanager put-secret-value --secret-id nexabank/mysql --region ap-south-1 \
  --secret-string "$(jq -nc --arg r 'ROOT_PW' --arg u 'nexabank' --arg p 'APP_PW' \
      '{root_password:$r, username:$u, password:$p}')"
aws secretsmanager put-secret-value --secret-id nexabank/grafana --region ap-south-1 \
  --secret-string "$(jq -nc --arg p 'GRAFANA_PW' '{username:"admin", password:$p}')"
```

Want random passwords instead? `./scripts/set-secrets.sh --generate`.

**You know it worked when** the keys print and the values do not:

```bash
aws secretsmanager get-secret-value --secret-id nexabank/mysql --query SecretString --output text | jq 'keys'
# ["password","root_password","username"]
```

> MySQL reads its password only when its volume is first created. Changing the MySQL secret later does
> **not** change the password inside an existing database and the app stops connecting. Choose it once
> before the first deploy; to change it afterwards, delete the MySQL PVC (this wipes the data).

## 7. Push

Done in step 3. If you changed anything since: `git push`. (`deploy.sh` warns about unpushed commits.)

---

### ══ HARD GATE ══

`scripts/deploy.sh` runs exactly these checks first and stops if one fails:

```bash
kubectl config current-context | grep nexabank-eks
kubectl get nodes --no-headers | wc -l                                       # 2
git ls-remote --exit-code --heads origin main
aws secretsmanager get-secret-value --secret-id nexabank/mysql   >/dev/null && echo ok
aws secretsmanager get-secret-value --secret-id nexabank/grafana >/dev/null && echo ok
grep -rhoE 'repoURL: https://github.com/\S+' gitops/argocd | sort -u         # only YOUR repo
```

---

## 8. Deploy the platform and the app

```bash
./scripts/deploy.sh                 # app from plain manifests (default)
./scripts/deploy.sh --mode helm     # or: app from the Helm chart
```

### Helm or plain manifests?

Both are in the repo and deploy the **same** thing (same resources, same names). Pick one:

| | Plain manifests (`k8s/`, default) | Helm chart (`helm/nexabank`) |
| --- | --- | --- |
| Readability | What you see is what is applied | Go templates (`{{ }}`) to read |
| Matches what you tested on kind | Yes | No |
| HTTPS on/off | Choose `k8s/gateway-http` or `k8s/gateway-https` (configure.sh switches it) | One flag, `gateway.hostname` |
| Settings (sizes, names, domain) | Edit the YAML | One `values.yaml` |
| Several environments (dev/prod) | Copy folders, or add Kustomize | Natural: one chart, a values file per environment |
| Image bump by CI | Edits the `image:` line | Edits `image.tag` in `values.yaml` |

For one app in one environment, plain manifests are simpler: choose them. Choose Helm if you will run
several environments or want to tune the app through one values file. The platform tools (Prometheus,
Loki, cert-manager...) are Helm charts in both cases: ArgoCD installs them and `gitops/observability/*-values.yaml` sets them.

**Switching later** is safe: apply the other Application (`kubectl apply -f gitops/argocd/nexabank-helm.yaml`). It has the
same name and creates the same resources, so ArgoCD just takes them over. Never apply both files. `bump.yml` updates both
deploy files on every build so they never drift. (Configure HTTPS in the mode you use; `configure.sh --domain` updates both.)

It is idempotent (safe to re-run after fixing something) and does this:

| # | Step | Manual equivalent |
| --- | --- | --- |
| 1 | Envoy Gateway + GatewayClass `envoy` (NLB) | `helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version v1.10.0 -n envoy-gateway-system --create-namespace --wait` then `kubectl apply -f gitops/gateway/gatewayclass.yaml` |
| 2 | Platform app-of-apps | `kubectl apply -f gitops/argocd/platform.yaml` |
| 3 | Waits for ESO, the `ClusterSecretStore`, cert-manager | |
| 4 | The application | `kubectl apply -f gitops/argocd/nexabank-raw.yaml` (or `nexabank-helm.yaml` with `--mode helm`) |
| 5 | Waits, prints status and the load balancer address | |

Envoy Gateway goes first because it installs the Gateway API CRDs, and cert-manager only checks for them at startup.

**You know it worked when:**

```bash
kubectl -n argocd get applications          # 12: platform + 10 children + nexabank, all Synced/Healthy (a few minutes)
kubectl get clustersecretstore aws-secrets-manager      # READY True
kubectl -n nexabank-ns get externalsecret nexabank-secret   # SecretSynced
kubectl -n nexabank-ns get pvc              # Bound, not Pending
kubectl -n nexabank-ns get pods
```

> Pods in `CreateContainerConfigError` for the first 30-60 seconds is **expected**: they start before
> ESO has produced the Secret and heal themselves. Worry after ~2 minutes (section 14).
> Do not continue until the `ClusterSecretStore` is Ready: it proves the region, the Pod Identity
> association and the IAM policy in one check.

ArgoCD UI (not exposed publicly):

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8080:80        # http://localhost:8080, user admin
```

## 9. Open the app and smoke test

```bash
ADDR=$(kubectl -n nexabank-ns get gateway nexabank-gateway -o jsonpath='{.status.addresses[0].value}')
echo "$ADDR"                     # appears after 2-3 min; the NLB needs a bit longer to answer
curl -s -o /dev/null -w '%{http_code}\n' "http://$ADDR/"
```

Ollama downloads its model (`qwen2.5:1.5b`, ~1 GB) on first start and only turns Ready after that:

```bash
kubectl -n nexabank-ns logs deploy/ollama -f
kubectl -n nexabank-ns exec deploy/ollama -- ollama list
```

> The load balancer is an AWS **NLB** (hostname, never a fixed IP) → HTTPS uses a **CNAME**.
> Each browser is pinned to one app pod by a cookie (`NEXABANK_AFFINITY`), because the app keeps login
> state in memory and Envoy ignores Service `sessionAffinity`.

## 10. HTTPS on your own domain

Order matters: the DNS record cannot exist before the load balancer does, and the certificate cannot be issued before DNS resolves.

1. Set the domain and a real email, push, and re-apply the Application (the Application object is applied by hand, so edits to it need a re-apply):
   ```bash
   ./scripts/configure.sh --domain nexabank.example.com --email you@example.com
   git add -A && git commit -m "enable https" && git push
   kubectl apply -f gitops/argocd/nexabank-raw.yaml        # or nexabank-helm.yaml in Helm mode
   kubectl -n argocd annotate app nexabank argocd.argoproj.io/refresh=hard --overwrite
   kubectl -n argocd annotate app cert-manager-config argocd.argoproj.io/refresh=hard --overwrite
   ```
   (Raw mode: this fills in `k8s/gateway-https/gateway.yaml` and points the Application at that folder instead of `k8s/gateway-http`.)
2. Get the hostname and create the DNS record at your DNS provider:
   ```bash
   kubectl -n nexabank-ns get gateway nexabank-gateway -o jsonpath='{.status.addresses[0].value}'; echo
   ```
   | Type | Name | Value |
   | --- | --- | --- |
   | CNAME | `nexabank` | the hostname above |

   It must be a CNAME, not an A record. **Do not continue until** `dig +short @8.8.8.8 nexabank.example.com` returns the NLB and
   `curl -s -o /dev/null -w '%{http_code}\n' http://nexabank.example.com/` returns 200.
   (Let's Encrypt allows only 5 failed validations per hostname per hour.)
3. The first certificate comes from **staging** (browsers warn: expected). cert-manager sees the annotation on the Gateway and creates the `nexabank-tls` secret:
   ```bash
   kubectl -n nexabank-ns get certificate,challenge        # READY True after ~1-2 min
   kubectl -n cert-manager get cm cert-manager -o jsonpath='{.data.config\.yaml}'   # must contain gatewayAPI: enabled: true
   ```
   If that flag is missing: `kubectl -n cert-manager rollout restart deploy cert-manager`.
4. Switch to a trusted certificate: change the issuer to `letsencrypt-prod` (raw mode: `cert-manager.io/cluster-issuer` in `k8s/gateway-https/gateway.yaml`; Helm mode: `clusterIssuer` in `gitops/argocd/nexabank-helm.yaml`), then
   ```bash
   git add -A && git commit -m "use production certificate" && git push
   kubectl apply -f gitops/argocd/nexabank-raw.yaml        # or nexabank-helm.yaml
   kubectl -n nexabank-ns delete certificate nexabank-tls --ignore-not-found
   kubectl -n nexabank-ns delete secret nexabank-tls --ignore-not-found
   kubectl -n nexabank-ns get certificate -w
   ```
   **You know it worked when** `curl -sI https://nexabank.example.com/ | head -1` is `200` and
   `kubectl -n nexabank-ns get secret nexabank-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer`
   does **not** say `(STAGING)`.
5. Plain HTTP on the domain now redirects (301) to HTTPS; the raw load balancer hostname keeps answering on HTTP.
   Renewal is automatic.

## 11. Observability

Nothing is public. Open Grafana through a port-forward:

```bash
# the password is the one you chose in step 6; to read it back:
aws secretsmanager get-secret-value --secret-id nexabank/grafana --query SecretString --output text | jq -r .password
kubectl -n observability port-forward svc/grafana 3000:80          # http://localhost:3000, user: admin
```

| Tool | Role | How you see it |
| --- | --- | --- |
| node-exporter | node CPU/memory/disk/network | Dashboards → *Node Exporter / Nodes* |
| cAdvisor | per-container CPU/memory (built into the kubelet; scraped by Prometheus, **no separate install**) | Dashboards → *Kubernetes / Compute Resources / Pod* → `nexabank-ns` |
| Prometheus | metrics (node, kube-state, app via PodMonitor) | `kubectl -n observability port-forward svc/prometheus-operated 9090` → Status → Targets |
| Grafana | UI, 3 datasources: Prometheus, Loki, Tempo | port-forward above |
| Promtail → Loki | container logs | Explore → Loki → `{namespace="nexabank-ns", app="nexabank"}` |
| OpenTelemetry Collector → Tempo | traces from the app's Java agent | Explore → Tempo → Search → service `nexabank` |

**Prove it works** (generate traffic first: `curl -s http://$ADDR/ >/dev/null` a few times, click around the app):

- Prometheus targets `nexabank-ns/nexabank`, `node-exporter`, `kubelet` (incl. `/metrics/cadvisor`), `kube-state-metrics` are **UP**.
- Query `jvm_memory_used_bytes{namespace="nexabank-ns"}` returns series; `http_server_requests_seconds_count` too.
- A Loki log line containing `trace_id=...` shows a **TraceID** button that opens the trace in Tempo; in a Tempo trace, *Logs for this span* jumps back.
- Optional dashboards: Dashboards → New → Import → ID **4701** (JVM Micrometer).

How the app is wired (environment variables in `k8s/app/nexabank-deployment.yaml` / `helm/nexabank/templates/nexabank-deployment.yaml`, **no code change**):

- `OTEL_EXPORTER_OTLP_ENDPOINT` → the collector. Your Dockerfile installs the Java agent and sets the exporter type but no endpoint, so traces used to go to `localhost` and vanish.
- `MANAGEMENT_SERVER_PORT=8081` + `health,prometheus`: metrics on a separate port that the Service and Gateway do **not** expose (the app's security config allows `/actuator/**` without login, so serving metrics on 8080 would make them public). Probes use 8081.
- `LOGGING_PATTERN_CONSOLE` adds `trace_id`/`span_id` for the log ↔ trace link.

Only traces use OpenTelemetry (your Dockerfile sets metrics/logs exporters to `none`): metrics come from Micrometer/Prometheus and logs from Promtail. Alertmanager is off (no receivers); the rules in `gitops/observability/manifests/` show under Prometheus → Alerts.

> **Promtail is deprecated** upstream (end of life). It is here because it was requested and works today.
> The replacement is Grafana Alloy: add an Application for the `grafana/alloy` chart with a `loki.source.kubernetes`
> + `loki.write` pipeline to `http://loki.observability.svc.cluster.local:3100/loki/api/v1/push`, confirm logs arrive,
> then delete `gitops/argocd/platform/observability-promtail.yaml`.

## 12. CI/CD

Push to `main` → `devsecops.yml` builds, scans, pushes `<user>/nexabank:sha-<7>` → `bump.yml` commits the new tag to
`k8s/app/nexabank-deployment.yaml` **and** `helm/nexabank/values.yaml` (`[skip ci]`) → ArgoCD rolls it out. Roll back by reverting that commit.
If `main` is branch-protected, allow `github-actions[bot]` to push. `terraform-ci.yml` lints `terraform/` on changes.
Never `kubectl edit` managed resources: `selfHeal` reverts them within minutes. Commit and push instead.

## 13. Tear it all down

The load balancer and the EBS volumes were not created by Terraform, so `terraform destroy` alone stalls on the VPC.

```bash
./scripts/destroy.sh               # asks you to type the cluster name; add --bootstrap to also delete the state bucket
```

It deletes the ArgoCD applications, then the namespaces (which removes the NLB and the volumes), waits until no
LoadBalancer or PVC is left, uninstalls Envoy Gateway, drops ArgoCD from Terraform state, checks for orphans, runs
`terraform destroy`, and lists leftover EBS volumes. Afterwards:

- delete the **DNS CNAME** for your domain (a CNAME to a released AWS name can be taken over);
- terminate the EC2 machine and delete its security group/role yourself (they were created by hand).

**Nothing is billing when these are empty:**

```bash
aws eks list-clusters --region ap-south-1
aws ec2 describe-volumes --region ap-south-1 --filters Name=status,Values=available --query 'Volumes[].VolumeId'
aws elbv2 describe-load-balancers --region ap-south-1 --query 'LoadBalancers[].LoadBalancerName'
aws secretsmanager list-secrets --region ap-south-1 --query 'SecretList[].Name'
```

## 14. Troubleshooting

| Symptom | Check / fix |
| --- | --- |
| `deploy.sh`: "repoURL differs" / "targetRevision" | `./scripts/configure.sh --repo USER/NexaBank --branch main`, commit, push |
| ArgoCD `ComparisonError` / app `Unknown` | branch not pushed, or `repoURL`/`targetRevision` wrong. `kubectl -n argocd logs deploy/argocd-repo-server --tail=50`, then `kubectl -n argocd annotate app <name> argocd.argoproj.io/refresh=hard --overwrite` |
| Pods `CreateContainerConfigError` > 2 min | `kubectl -n nexabank-ns describe externalsecret nexabank-secret`; `kubectl get clustersecretstore aws-secrets-manager -o yaml`; `kubectl -n external-secrets logs deploy/external-secrets`. Causes: step 6 not run; region in `cluster-secret-store.yaml` wrong (`ResourceNotFoundException`); Pod Identity missing (`AccessDeniedException`) |
| PVC `Pending` | `kubectl get storageclass` (gp3 default?); `kubectl -n kube-system get pods | grep ebs-csi`; or the pod it waits for is unschedulable (`describe pod`) |
| Pods `Pending` insufficient cpu/memory | nodes too small: raise `node_instance_type` / `node_desired_count` in `terraform.tfvars`, `terraform apply` |
| Gateway has no address after 5 min | `kubectl -n nexabank-ns describe gateway nexabank-gateway`; `kubectl -n envoy-gateway-system get pods,svc`; public subnets need the `kubernetes.io/role/elb` tag (set in `vpc.tf`) |
| App Application `ComparisonError` about PodMonitor/ExternalSecret | CRDs not there yet; it retries by itself, or press Sync once Prometheus/ESO are Healthy |
| Certificate stuck | `kubectl -n nexabank-ns describe certificate,challenge`; DNS not propagated; cert-manager started before Envoy Gateway (restart it, step 10.3); `rateLimited` → wait an hour, use staging |
| Browser says certificate invalid | still on the staging issuer (step 10.4) |
| Observability app `Degraded` | `kubectl -n argocd get app observability-loki -o yaml | less` (conditions). Loki/Tempo/OTel chart values change between versions: compare with the chart's `values.yaml` |
| No traces | `kubectl -n observability logs deploy/otel-collector`; `kubectl -n nexabank-ns exec deploy/nexabank -- env | grep OTEL` |
| Nothing you change sticks | `selfHeal: true`: commit and push instead of `kubectl edit` |
| `terraform apply` helm/kubernetes provider error on the first run | re-run; the providers connect to a cluster created in the same run |

## 15. Things to know

- Before real users, read `BEST-PRACTICES.md` (hardening checklist, in priority order).
- **Not validated end to end.** The Terraform, Helm chart, manifests and scripts were written against the devboard reference and the
  charts' own value files and checked for syntax (HCL, YAML, `bash -n`, `shellcheck`, `ansible --syntax-check`), but
  `terraform validate/plan`, `helm lint/template` and a real deploy were not run. Expect to fix a detail or two on the first run
  (usually a chart value key); `terraform-ci.yml` will run `validate`/`tflint` for you on push.
- Chart versions are pinned in `gitops/argocd/platform/*.yaml` and `terraform/variables.tf`/`argocd.tf`. Loki and Tempo come from the
  `grafana-community` Helm repo (they moved from `grafana/helm-charts`).
- The old `k8s/` folder and `DEPLOYMENT.md` from earlier iterations are no longer used.
- Dependabot watches Maven and GitHub Actions only; Terraform/Helm versions are bumped by hand.
- Grafana and ArgoCD stay private (port-forward). Exposing them is deliberately not part of this setup.
