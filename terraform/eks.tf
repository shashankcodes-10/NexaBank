# EKS cluster (terraform-aws-modules/eks v21), same shape as the devboard reference.
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.name
  kubernetes_version = var.cluster_version

  endpoint_public_access  = true
  endpoint_private_access = true

  # Whoever runs `terraform apply` (your EC2 machine's IAM role) becomes cluster admin.
  # Run kubectl from the same identity.
  enable_cluster_creator_admin_permissions = true

  addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent    = true
      before_compute = true
    }
    eks-pod-identity-agent = {
      most_recent    = true
      before_compute = true
    }
    # IAM comes from the Pod Identity association in pod-identity.tf
    aws-ebs-csi-driver = {
      most_recent = true
    }
    # needed by the HPA
    metrics-server = {
      most_recent = true
    }
  }

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = [var.node_instance_type]

      desired_size = var.node_desired_count
      min_size     = var.node_desired_count
      max_size     = var.node_max_count

      # disk_size is ignored by module v21: the root volume is set here.
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.node_disk_size
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      tags = {
        NodeGroup = "nexabank"
      }
    }
  }

  tags = local.tags
}
