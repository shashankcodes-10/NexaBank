# ArgoCD is the only thing Terraform installs inside the cluster.
# Everything else is installed by scripts/deploy.sh and then owned by ArgoCD.
resource "helm_release" "argocd" {
  count = var.enable_argocd ? 1 : 0

  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version

  namespace        = "argocd"
  create_namespace = true

  wait    = true
  timeout = 900

  values = [
    yamlencode({
      configs = {
        params = {
          # plain HTTP behind kubectl port-forward
          "server.insecure" = true
        }
      }
      server = {
        service = {
          type = "ClusterIP"
        }
      }
      # not used here, saves memory
      dex           = { enabled = false }
      notifications = { enabled = false }
    })
  ]

  depends_on = [module.eks]
}
