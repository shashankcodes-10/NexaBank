# EKS ships gp2 but marks no StorageClass default, so a PVC without a class hangs Pending.
# gp3, encrypted, default.
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"

    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner = "ebs.csi.aws.com"

  # Delete: `terraform destroy` / PVC deletion also removes the EBS volume (no orphan cost).
  # Use "Retain" if the data must survive.
  reclaim_policy         = "Delete"
  allow_volume_expansion = true

  # schedule the pod first, or the EBS volume lands in the wrong AZ
  volume_binding_mode = "WaitForFirstConsumer"

  parameters = {
    type      = "gp3"
    encrypted = "true"
    fsType    = "ext4"
  }

  depends_on = [module.eks]
}
