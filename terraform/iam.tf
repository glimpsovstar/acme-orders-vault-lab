data "aws_caller_identity" "current" {}

locals {
  # Actions from the Vault aws-sm sync docs (developer.hashicorp.com/vault/docs/sync/awssm),
  # plus DescribeSecret, which Vault calls on every sync (seen in CloudTrail),
  # scoped to this account, region and name prefix.
  sync_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:Create*",
        "secretsmanager:Update*",
        "secretsmanager:Delete*",
        "secretsmanager:TagResource",
        "secretsmanager:DescribeSecret",
      ]
      Resource = ["arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.aws_secret_name_prefix}*"]
    }]
  })

  oidc_host = var.vault_oidc_issuer == null ? "" : trimprefix(var.vault_oidc_issuer, "https://")
}

# Instance role: Vault AWS auth identity, the synced secret, and the app bundle.
resource "aws_iam_role" "instance" {
  name_prefix = "${var.name}-instance-"
  description = "Acme Orders lab instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "instance" {
  name = "acme-orders"
  role = aws_iam_role.instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadSyncedSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = ["arn:aws:secretsmanager:${var.region}:*:secret:${var.aws_secret_name_prefix}*"]
      },
      {
        Sid      = "VaultAwsAuth"
        Effect   = "Allow"
        Action   = ["sts:GetCallerIdentity"]
        Resource = ["*"]
      },
      {
        Sid      = "AppBundle"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.app.arn}/${local.bundle_key}"]
      },
    ]
  })
}

resource "aws_iam_instance_profile" "app" {
  name_prefix = "${var.name}-"
  role        = aws_iam_role.instance.name
}

# Sync principal, option 1: an IAM user. Its access key is created outside
# Terraform with scripts/sync-user-keys.sh, so the key is never in state.
resource "aws_iam_user" "sync" {
  count = var.sync_auth == "iam_user" ? 1 : 0

  name                 = var.sync_user_name
  permissions_boundary = var.sync_user_permissions_boundary_arn
  force_destroy        = true
}

resource "aws_iam_user_policy_attachment" "sync" {
  for_each = var.sync_auth == "iam_user" ? toset(var.sync_user_policy_arns) : toset([])

  user       = aws_iam_user.sync[0].name
  policy_arn = each.value
}

resource "aws_iam_user_policy" "sync" {
  count = var.sync_auth == "iam_user" ? 1 : 0

  name   = "vault-secrets-sync"
  user   = aws_iam_user.sync[0].name
  policy = local.sync_policy
}

# Sync principal, option 2: workload identity federation with Vault's token issuer.
# With sync_auth = none, Terraform creates neither option.
resource "aws_iam_openid_connect_provider" "vault" {
  count = var.sync_auth == "wif" ? 1 : 0

  url            = var.vault_oidc_issuer
  client_id_list = [var.vault_oidc_audience]
}

resource "aws_iam_role" "sync" {
  count = var.sync_auth == "wif" ? 1 : 0

  name_prefix = "${var.name}-vault-sync-"
  description = "Vault secrets sync to Secrets Manager"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.vault[0].arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_host}:aud" = var.vault_oidc_audience
          "${local.oidc_host}:sub" = var.vault_oidc_subject
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "sync" {
  count = var.sync_auth == "wif" ? 1 : 0

  name   = "vault-secrets-sync"
  role   = aws_iam_role.sync[0].id
  policy = local.sync_policy
}
