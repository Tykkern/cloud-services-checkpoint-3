#!/usr/bin/env bash
# Подъём стенда КТ3 по шагам: bash scripts/setup.sh <шаг>
#   cluster  - kind-кластер kt3 и настройка containerd для локального registry
#   infra    - registry, GitLab, namespace и RBAC для CI, ArgoCD core
#   gitlab   - ждёт GitLab, создаёт токен root, проекты hello-app и config-repo, отключает Auto DevOps
#   runner   - регистрирует instance runner через API и ставит GitLab Runner из Helm-чарта
#   gitops   - токены config-repo для CI и ArgoCD, Application hello
# Секреты (пароль root, токены) пишутся в .secrets/ и в git не попадают.
set -euo pipefail

cd "$(dirname "$0")/.."
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/kt3}"
GITLAB=http://localhost:8930
REGISTRY_HOST=registry.registry.svc.cluster.local:5000
mkdir -p .secrets

rand() { python -c "import secrets,string; a=string.ascii_letters+string.digits; print(''.join(secrets.choice(a) for _ in range($1)))"; }
api() { curl -sf -H "PRIVATE-TOKEN: $(cat .secrets/root-token)" "$@"; }
project_id() { api "$GITLAB/api/v4/projects/root%2F$1" | python -c "import sys,json; print(json.load(sys.stdin)['id'])"; }

case "${1:-}" in
cluster)
  kind create cluster --config k8s/kind-config.yaml --kubeconfig "$KUBECONFIG"
  # Нода не резолвит DNS кластера, поэтому имя сервиса registry связываем с его фиксированным ClusterIP
  docker exec kt3-control-plane sh -c "mkdir -p /etc/containerd/certs.d/$REGISTRY_HOST && printf '%s\n' 'server = \"http://10.96.50.50:5000\"' '' '[host.\"http://10.96.50.50:5000\"]' '  capabilities = [\"pull\", \"resolve\"]' > /etc/containerd/certs.d/$REGISTRY_HOST/hosts.toml"
  ;;
infra)
  kubectl apply -f k8s/registry.yaml -f k8s/gitlab.yaml -f k8s/ci-rbac.yaml
  [ -f .secrets/root-password ] || rand 24 > .secrets/root-password
  kubectl -n gitlab create secret generic gitlab-root --from-literal=password="$(cat .secrets/root-password)" --dry-run=client -o yaml | kubectl apply -f -
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.6/manifests/core-install.yaml
  # public.ecr.aws из РФ не отдаёт слои (таймаут CloudFront), тот же образ redis берём с Docker Hub
  kubectl -n argocd set image deployment/argocd-redis redis=docker.io/library/redis:8.2.3-alpine
  # По умолчанию ArgoCD опрашивает git раз в 3 минуты, для стенда хватит минуты
  kubectl -n argocd patch configmap argocd-cm --type merge -p '{"data":{"timeout.reconciliation":"60s"}}'
  ;;
gitlab)
  kubectl -n gitlab wait --for=condition=Ready pod -l app=gitlab --timeout=20m
  if [ ! -f .secrets/root-token ]; then
    token="glpat-$(rand 20)"
    kubectl -n gitlab exec deploy/gitlab -- gitlab-rails runner "t = User.find_by_username('root').personal_access_tokens.create!(scopes: ['api', 'write_repository'], name: 'kt3-setup', expires_at: 7.days.from_now); t.set_token('$token'); t.save!"
    echo "$token" > .secrets/root-token
  fi
  api -X PUT "$GITLAB/api/v4/application/settings?auto_devops_enabled=false" > /dev/null
  for p in hello-app config-repo; do
    api "$GITLAB/api/v4/projects/root%2F$p" > /dev/null 2>&1 || api -X POST "$GITLAB/api/v4/projects" -d "name=$p" -d "visibility=private" > /dev/null
  done
  echo "GitLab: $GITLAB (root, пароль в .secrets/root-password)"
  ;;
runner)
  if ! kubectl -n ci get secret gitlab-runner-token > /dev/null 2>&1; then
    token=$(api -X POST "$GITLAB/api/v4/user/runners" -d "runner_type=instance_type" -d "run_untagged=true" -d "description=kind-kt3" | python -c "import sys,json; print(json.load(sys.stdin)['token'])")
    kubectl -n ci create secret generic gitlab-runner-token --from-literal=runner-registration-token="" --from-literal=runner-token="$token"
  fi
  helm upgrade --install gitlab-runner gitlab-runner --repo https://charts.gitlab.io --version 0.94.2 -n ci -f k8s/gitlab-runner-values.yaml
  ;;
gitops)
  config_id=$(project_id config-repo)
  app_id=$(project_id hello-app)
  expires=$(date -d '+7 days' +%F)
  # CI пишет в config-repo своим токеном (Maintainer, только write_repository)
  ci_token=$(api -X POST "$GITLAB/api/v4/projects/$config_id/access_tokens" -d "name=ci-push" -d "scopes[]=write_repository" -d "access_level=40" -d "expires_at=$expires" | python -c "import sys,json; print(json.load(sys.stdin)['token'])")
  api -X POST "$GITLAB/api/v4/projects/$app_id/variables" -d "key=CONFIG_REPO_TOKEN" --data-urlencode "value=$ci_token" -d "masked=true" > /dev/null
  # ArgoCD только читает config-repo (Reporter, read_repository)
  argo_token=$(api -X POST "$GITLAB/api/v4/projects/$config_id/access_tokens" -d "name=argocd-read" -d "scopes[]=read_repository" -d "access_level=20" -d "expires_at=$expires" | python -c "import sys,json; print(json.load(sys.stdin)['token'])")
  kubectl -n argocd create secret generic config-repo --from-literal=type=git --from-literal=url=http://gitlab.gitlab.svc.cluster.local:8930/root/config-repo.git --from-literal=username=argocd --from-literal=password="$argo_token" --dry-run=client -o yaml | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml | kubectl apply -f -
  kubectl apply -f argocd/project.yaml -f argocd/application.yaml
  ;;
*)
  echo "usage: $0 cluster|infra|gitlab|runner|gitops" >&2
  exit 1
  ;;
esac
