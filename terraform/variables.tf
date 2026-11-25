variable "region" {
  type        = string
  description = "AWS region for the lab, and the region of the synced secret."
  default     = "ap-southeast-2"

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.region))
    error_message = "region must be an AWS region name such as ap-southeast-2."
  }
}

variable "name" {
  type        = string
  description = "Name prefix for every lab resource."
  default     = "acme-orders"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.name))
    error_message = "Use 2 to 31 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "default_tags" {
  type        = map(string)
  description = "Tags added to every resource the AWS provider creates."
  default     = { Project = "acme-orders-kv-sync" }
}

variable "image_id" {
  type        = string
  description = "AMI ID for the app instance. Bring your own approved image: RHEL 9 or Amazon Linux 2023."

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.image_id))
    error_message = "image_id must be an AMI ID such as ami-0123456789abcdef0."
  }
}

variable "subnet_id" {
  type        = string
  description = "Public subnet for the app instance. It needs a route to the internet."

  validation {
    condition     = can(regex("^subnet-[0-9a-f]{8,17}$", var.subnet_id))
    error_message = "subnet_id must be a subnet ID such as subnet-0123456789abcdef0."
  }
}

variable "operator_cidr" {
  type        = string
  description = "Your workstation's public IPv4 address as a /32. Only this range reaches the app and SSH."

  validation {
    condition     = can(cidrnetmask(var.operator_cidr)) && try(tonumber(split("/", var.operator_cidr)[1]) > 0, false)
    error_message = "operator_cidr must be an IPv4 CIDR such as 198.51.100.7/32. 0.0.0.0/0 is refused."
  }
}

variable "ssh_key_name" {
  type        = string
  description = "Existing EC2 key pair name for SSH. Leave null if your image provides access another way."
  default     = null
}

variable "app_source_dir" {
  type        = string
  description = "Folder that holds the Acme Orders source and its Containerfile. A relative path is taken from this terraform folder. With the acme-orders-vault-demo repository cloned beside this one, use ../../acme-orders-vault-demo."
  default     = "../../app"

  validation {
    condition     = length(trimspace(var.app_source_dir)) > 0
    error_message = "app_source_dir must not be empty. Set it to the folder that holds the app's Containerfile."
  }
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type. The default has 4 GiB, room for the app, Postgres and the OS package cache. 2 GiB ran out of memory."
  default     = "t3.medium"
}

variable "vault_addr" {
  type        = string
  description = "HCP Vault public address, for example https://example.vault.hashicorp.cloud:8200."

  validation {
    condition     = can(regex("^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9/_.-]*)?$", var.vault_addr))
    error_message = "vault_addr must be a plain https:// URL such as https://example.vault.hashicorp.cloud:8200."
  }
}

variable "vault_namespace" {
  type        = string
  description = "Vault namespace the app logs in to."
  default     = "admin/kv-sync-poc"

  validation {
    condition     = can(regex("^[A-Za-z0-9/_+=.@:-]*$", var.vault_namespace))
    error_message = "vault_namespace may hold only letters, digits and /_+=.@:- characters."
  }
}

variable "vault_iam_server_id" {
  type        = string
  description = "Value of iam_server_id_header_value on the Vault AWS auth mount, if one is set."
  default     = ""

  validation {
    condition     = can(regex("^[A-Za-z0-9/_+=.@:-]*$", var.vault_iam_server_id))
    error_message = "vault_iam_server_id may hold only letters, digits and /_+=.@:- characters."
  }
}

variable "vault_iam_sts_region" {
  type        = string
  description = "Region the app signs its Vault IAM login for. Keep us-east-1 unless the AWS auth mount uses a regional STS endpoint."
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.vault_iam_sts_region))
    error_message = "vault_iam_sts_region must be an AWS region name such as us-east-1."
  }
}

variable "aws_secret_name" {
  type        = string
  description = "Name of the synced secret in Secrets Manager. Empty until sync is set up. Only the first boot reads this; change it later on the instance."
  default     = ""

  validation {
    condition     = can(regex("^[A-Za-z0-9/_+=.@-]*$", var.aws_secret_name))
    error_message = "aws_secret_name may hold only letters, digits and /_+=.@- characters."
  }
}

variable "sync_auth" {
  type        = string
  description = "How Vault secrets sync signs in to AWS: iam_user (an IAM user whose keys you create out of band), wif (workload identity federation), or none (Terraform creates no sync identity; bring your own)."
  default     = "iam_user"

  validation {
    condition     = contains(["iam_user", "wif", "none"], var.sync_auth)
    error_message = "sync_auth must be iam_user, wif or none."
  }
}

variable "sync_user_name" {
  type        = string
  description = "iam_user only: name of the sync IAM user. Change it if your account requires a naming pattern for IAM users."
  default     = "acme-orders-sync"

  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@_-]{1,64}$", var.sync_user_name))
    error_message = "sync_user_name must be 1 to 64 letters, digits or +=,.@_- characters."
  }
}

variable "sync_user_permissions_boundary_arn" {
  type        = string
  description = "iam_user only: managed policy ARN to set as the sync user's permissions boundary, if your account requires one."
  default     = null

  validation {
    condition     = var.sync_user_permissions_boundary_arn == null || can(regex("^arn:aws[a-z-]*:iam::([0-9]{12}|aws):policy/.+$", var.sync_user_permissions_boundary_arn))
    error_message = "sync_user_permissions_boundary_arn must be an IAM policy ARN."
  }
}

variable "sync_user_policy_arns" {
  type        = list(string)
  description = "iam_user only: extra managed policy ARNs to attach to the sync user, if your account requires them. The scoped inline sync policy is always added."
  default     = []

  validation {
    condition     = alltrue([for a in var.sync_user_policy_arns : can(regex("^arn:aws[a-z-]*:iam::([0-9]{12}|aws):policy/.+$", a))])
    error_message = "Each sync_user_policy_arns entry must be an IAM policy ARN."
  }
}

variable "vault_oidc_issuer" {
  type        = string
  description = "wif only: the Vault plugin identity token issuer URL, https://<host>:8200/v1/<namespace>/identity/oidc/plugins, after vault write identity/oidc/config issuer=<Vault public address> in that namespace."
  default     = null

  validation {
    condition     = var.sync_auth != "wif" || try(startswith(var.vault_oidc_issuer, "https://"), false)
    error_message = "With sync_auth = wif, vault_oidc_issuer must be set and start with https://."
  }
}

variable "vault_oidc_audience" {
  type        = string
  description = "wif only: the audience Vault puts in its identity tokens (identity_token_audience on the destination), for example sts.amazonaws.com."
  default     = null

  validation {
    condition     = var.sync_auth != "wif" || try(length(var.vault_oidc_audience) > 0, false)
    error_message = "With sync_auth = wif, vault_oidc_audience must be set."
  }
}

variable "vault_oidc_subject" {
  type        = string
  description = "wif only: the subject Vault sends for this sync destination, secrets-sync:<namespace path>:aws-sm:<destination name>. Record the exact value from the live run."
  default     = null

  validation {
    condition     = var.sync_auth != "wif" || try(length(trimspace(var.vault_oidc_subject)) > 0, false)
    error_message = "With sync_auth = wif, vault_oidc_subject must be set, so the role trusts only this sync destination."
  }
}

variable "aws_secret_name_prefix" {
  type        = string
  description = "Prefix of the synced secret names in Secrets Manager. A Vault sync destination name template of vault/{{ .MountPath }}/{{ .SecretPath }} gives vault/app/<path> for the app mount. Sync and the instance role are limited to it."
  default     = "vault/app/"

  validation {
    condition     = can(regex("^[A-Za-z0-9/_+=.@-]+$", var.aws_secret_name_prefix))
    error_message = "aws_secret_name_prefix must be non-empty, with only letters, digits and /_+=.@- characters (no *)."
  }
}

variable "aws_cli_image" {
  type        = string
  description = "Container image the instance uses to fetch the app bundle from S3."
  default     = "public.ecr.aws/aws-cli/aws-cli:2.22.0"

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9/_.@:-]*$", var.aws_cli_image))
    error_message = "aws_cli_image must be a plain image reference such as public.ecr.aws/aws-cli/aws-cli:2.22.0."
  }
}
