# Offline tests for the lab. The aws provider is mocked, so nothing is created.
# The archive provider is real: it zips the app_source_dir folder into .build/ here.

mock_provider "aws" {
  override_resource {
    target = aws_s3_bucket.app
    values = {
      bucket = "acme-orders-app-test"
      arn    = "arn:aws:s3:::acme-orders-app-test"
    }
  }
  override_resource {
    target = aws_iam_role.instance
    values = {
      arn = "arn:aws:iam::111122223333:role/acme-orders-instance"
    }
  }
  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "111122223333"
    }
  }
  override_resource {
    target = aws_instance.app
    values = {
      public_ip = "203.0.113.10"
    }
  }
}

variables {
  image_id      = "ami-0123456789abcdef0"
  subnet_id     = "subnet-0123456789abcdef0"
  operator_cidr = "198.51.100.7/32"
  vault_addr    = "https://vault.example.com:8200"
}

run "iam_user_default" {
  command = apply

  # Security group: app port and SSH, only from the operator CIDR.
  assert {
    condition     = aws_vpc_security_group_ingress_rule.app.from_port == 8080 && aws_vpc_security_group_ingress_rule.app.to_port == 8080
    error_message = "The app rule must open port 8080 only."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.ssh.from_port == 22 && aws_vpc_security_group_ingress_rule.ssh.to_port == 22
    error_message = "The SSH rule must open port 22 only."
  }
  assert {
    condition = alltrue([
      aws_vpc_security_group_ingress_rule.app.cidr_ipv4 == var.operator_cidr,
      aws_vpc_security_group_ingress_rule.ssh.cidr_ipv4 == var.operator_cidr,
    ])
    error_message = "Ingress must come only from var.operator_cidr."
  }
  assert {
    condition = alltrue([
      aws_vpc_security_group_ingress_rule.app.cidr_ipv4 != "0.0.0.0/0",
      aws_vpc_security_group_ingress_rule.ssh.cidr_ipv4 != "0.0.0.0/0",
      aws_vpc_security_group_ingress_rule.app.cidr_ipv6 == null,
      aws_vpc_security_group_ingress_rule.ssh.cidr_ipv6 == null,
    ])
    error_message = "Ingress must never be open to the world."
  }

  # Instance role: read only the synced secrets, prove its identity, fetch the app bundle.
  assert {
    condition = toset(flatten([
      for s in jsondecode(aws_iam_role_policy.instance.policy).Statement : s.Action
    ])) == toset(["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret", "sts:GetCallerIdentity", "s3:GetObject"])
    error_message = "The instance role must have exactly the four expected actions."
  }
  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.instance.policy).Statement : s.Resource
      if contains(flatten([s.Action]), "secretsmanager:GetSecretValue")
    ]) == ["arn:aws:secretsmanager:ap-southeast-2:*:secret:vault/app/*"]
    error_message = "Secrets Manager reads must be limited to secret:vault/app/* in ap-southeast-2."
  }
  assert {
    condition = toset(flatten(one([
      for s in jsondecode(aws_iam_role_policy.instance.policy).Statement : s.Action
      if contains(flatten([s.Resource]), "arn:aws:secretsmanager:ap-southeast-2:*:secret:vault/app/*")
    ]))) == toset(["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"])
    error_message = "Only GetSecretValue and DescribeSecret may apply to the synced secrets."
  }
  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.instance.policy).Statement :
      contains(flatten([s.Action]), "sts:GetCallerIdentity") && s.Effect == "Allow"
    ])
    error_message = "The instance role needs sts:GetCallerIdentity."
  }
  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.instance.policy).Statement : s.Resource
      if contains(flatten([s.Action]), "s3:GetObject")
    ]) == ["arn:aws:s3:::acme-orders-app-test/acme-orders/app.zip"]
    error_message = "s3:GetObject must be limited to the one app bundle object."
  }
  assert {
    condition     = aws_iam_role_policy.instance.role == aws_iam_role.instance.id
    error_message = "The instance policy must be attached to the instance role."
  }

  # Sync principal: an IAM user with the policy from the Vault aws-sm docs.
  assert {
    condition     = length(aws_iam_user.sync) == 1 && length(aws_iam_role.sync) == 0 && length(aws_iam_openid_connect_provider.vault) == 0
    error_message = "iam_user mode creates one IAM user and no WIF resources."
  }
  assert {
    condition = jsondecode(aws_iam_user_policy.sync[0].policy).Statement == [{
      Effect   = "Allow"
      Action   = ["secretsmanager:Create*", "secretsmanager:Update*", "secretsmanager:Delete*", "secretsmanager:TagResource", "secretsmanager:DescribeSecret"]
      Resource = ["arn:aws:secretsmanager:ap-southeast-2:111122223333:secret:vault/app/*"]
    }]
    error_message = "The sync policy must match the Vault aws-sm docs."
  }
  assert {
    condition     = aws_iam_user.sync[0].force_destroy == true
    error_message = "The sync user must delete its out-of-band access keys on destroy."
  }
  assert {
    condition     = aws_iam_user.sync[0].name == "acme-orders-sync" && aws_iam_user.sync[0].permissions_boundary == null && length(aws_iam_user_policy_attachment.sync) == 0
    error_message = "By default the sync user is acme-orders-sync, with no boundary and no extra managed policies."
  }

  # Instance: customer image, IMDSv2 with a hop limit the container can use.
  assert {
    condition     = aws_instance.app.ami == var.image_id && aws_instance.app.subnet_id == var.subnet_id
    error_message = "The instance must use the image and subnet given."
  }
  assert {
    condition     = aws_instance.app.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required."
  }
  assert {
    condition     = aws_instance.app.metadata_options[0].http_put_response_hop_limit == 2
    error_message = "The IMDS hop limit must be 2 so the app container reaches the instance role."
  }
  assert {
    condition     = aws_instance.app.iam_instance_profile == aws_iam_instance_profile.app.name
    error_message = "The instance must use the lab instance profile."
  }
  assert {
    condition     = aws_instance.app.user_data_replace_on_change == false
    error_message = "Changing user-data must not replace the instance."
  }

  # User-data: small enough, the right app settings, no podman-compose.
  assert {
    condition     = length(local.user_data) < 16384
    error_message = "User-data must stay under 16 KB."
  }
  assert {
    condition = alltrue([
      strcontains(local.user_data, "VAULT_ADDR=https://vault.example.com:8200"),
      strcontains(local.user_data, "VAULT_NAMESPACE=admin/kv-sync-poc"),
      strcontains(local.user_data, "AWS_REGION=ap-southeast-2"),
      strcontains(local.user_data, "KVS_AWS_SECRET_NAME=\n"),
      strcontains(local.user_data, "KVS_IAM_STS_REGION=us-east-1"),
      strcontains(local.user_data, "s3://acme-orders-app-test/acme-orders/app.zip"),
    ])
    error_message = "User-data must carry the app settings and the bundle location."
  }
  assert {
    condition     = !strcontains(local.user_data, "podman-compose") && !strcontains(local.user_data, "podman compose")
    error_message = "User-data must not depend on podman-compose."
  }

  # Bundle: private, encrypted bucket.
  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.app.block_public_acls,
      aws_s3_bucket_public_access_block.app.block_public_policy,
      aws_s3_bucket_public_access_block.app.ignore_public_acls,
      aws_s3_bucket_public_access_block.app.restrict_public_buckets,
    ])
    error_message = "The bundle bucket must block all public access."
  }
  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.app.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "The bundle bucket must encrypt at rest."
  }
  assert {
    condition     = aws_s3_bucket.app.force_destroy == true
    error_message = "The bundle bucket must be removable on lab teardown."
  }

  # Outputs: the four from the brief, none holding a key.
  assert {
    condition     = output.app_url == "http://203.0.113.10:8080"
    error_message = "app_url must be http://<public ip>:8080."
  }
  assert {
    condition     = output.instance_role_arn == "arn:aws:iam::111122223333:role/acme-orders-instance"
    error_message = "instance_role_arn must be the instance role ARN."
  }
  assert {
    condition     = output.aws_secret_name_prefix == "vault/app/"
    error_message = "aws_secret_name_prefix must default to vault/app/."
  }
  assert {
    condition     = output.sync_principal == aws_iam_user.sync[0].name
    error_message = "In iam_user mode sync_principal is the user name."
  }
  assert {
    condition = !can(regex("(AKIA|ASIA)[A-Z0-9]{16}|[A-Za-z0-9/+]{40}", jsonencode([
      output.app_url, output.instance_role_arn, output.aws_secret_name_prefix, output.sync_principal,
    ])))
    error_message = "No output may hold an access key."
  }
}

run "wif" {
  command = apply

  variables {
    sync_auth           = "wif"
    vault_oidc_issuer   = "https://vault.example.com:8200/v1/admin/kv-sync-poc/identity/oidc/plugins"
    vault_oidc_audience = "sts.amazonaws.com"
    vault_oidc_subject  = "secrets-sync:admin/kv-sync-poc:aws-sm:acme"
  }

  assert {
    condition     = length(aws_iam_user.sync) == 0 && length(aws_iam_role.sync) == 1 && length(aws_iam_openid_connect_provider.vault) == 1
    error_message = "wif mode creates the OIDC provider and role, and no IAM user."
  }
  assert {
    condition     = aws_iam_openid_connect_provider.vault[0].url == var.vault_oidc_issuer && toset(aws_iam_openid_connect_provider.vault[0].client_id_list) == toset([var.vault_oidc_audience])
    error_message = "The OIDC provider must use the Vault issuer and audience."
  }
  assert {
    condition = jsondecode(aws_iam_role.sync[0].assume_role_policy).Statement[0].Condition.StringEquals == {
      "vault.example.com:8200/v1/admin/kv-sync-poc/identity/oidc/plugins:aud" = "sts.amazonaws.com"
      "vault.example.com:8200/v1/admin/kv-sync-poc/identity/oidc/plugins:sub" = "secrets-sync:admin/kv-sync-poc:aws-sm:acme"
    }
    error_message = "The role must trust only tokens with the Vault audience and this destination's subject."
  }
  assert {
    condition     = jsondecode(aws_iam_role.sync[0].assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity"
    error_message = "The role must be assumed with a web identity."
  }
  assert {
    condition = jsondecode(aws_iam_role_policy.sync[0].policy).Statement == [{
      Effect   = "Allow"
      Action   = ["secretsmanager:Create*", "secretsmanager:Update*", "secretsmanager:Delete*", "secretsmanager:TagResource", "secretsmanager:DescribeSecret"]
      Resource = ["arn:aws:secretsmanager:ap-southeast-2:111122223333:secret:vault/app/*"]
    }]
    error_message = "The sync role policy must match the Vault aws-sm docs."
  }
  assert {
    condition     = output.sync_principal == aws_iam_role.sync[0].arn
    error_message = "In wif mode sync_principal is the role ARN."
  }
}

run "wif_needs_subject" {
  command = plan

  variables {
    sync_auth           = "wif"
    vault_oidc_issuer   = "https://vault.example.com:8200/v1/identity/oidc/plugins"
    vault_oidc_audience = "sts.amazonaws.com"
    vault_oidc_subject  = ""
  }

  expect_failures = [var.vault_oidc_subject]
}

run "secret_name_and_region_flow_through" {
  command = apply

  variables {
    region                 = "ap-southeast-4"
    aws_secret_name        = "vault/kv_1234/app/db"
    vault_iam_server_id    = "vault.example.com"
    aws_secret_name_prefix = "acme/"
  }

  assert {
    condition = alltrue([
      strcontains(local.user_data, "KVS_AWS_SECRET_NAME=vault/kv_1234/app/db"),
      strcontains(local.user_data, "KVS_IAM_SERVER_ID=vault.example.com"),
      strcontains(local.user_data, "AWS_REGION=ap-southeast-4"),
    ])
    error_message = "Secret name, server ID and region must reach the app env file."
  }
  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.instance.policy).Statement : s.Resource
      if contains(flatten([s.Action]), "secretsmanager:GetSecretValue")
    ]) == ["arn:aws:secretsmanager:ap-southeast-4:*:secret:acme/*"]
    error_message = "The Secrets Manager scope must follow var.region and the prefix."
  }
  assert {
    condition     = jsondecode(aws_iam_user_policy.sync[0].policy).Statement[0].Resource == ["arn:aws:secretsmanager:ap-southeast-4:111122223333:secret:acme/*"]
    error_message = "The sync scope must follow var.region, the account and the prefix."
  }
  assert {
    condition     = output.aws_secret_name_prefix == "acme/"
    error_message = "aws_secret_name_prefix output must follow the variable."
  }
}

run "refuses_open_world_cidr" {
  command = plan

  variables {
    operator_cidr = "0.0.0.0/0"
  }

  expect_failures = [var.operator_cidr]
}

run "refuses_bad_cidr" {
  command = plan

  variables {
    operator_cidr = "not-a-cidr"
  }

  expect_failures = [var.operator_cidr]
}

run "refuses_unknown_sync_auth" {
  command = plan

  variables {
    sync_auth = "access_key"
  }

  expect_failures = [var.sync_auth]
}

run "wif_needs_issuer" {
  command = plan

  variables {
    sync_auth = "wif"
  }

  expect_failures = [var.vault_oidc_issuer, var.vault_oidc_audience, var.vault_oidc_subject]
}

run "refuses_wildcard_prefix" {
  command = plan

  variables {
    aws_secret_name_prefix = "vault*"
  }

  expect_failures = [var.aws_secret_name_prefix]
}

run "refuses_empty_prefix" {
  command = plan

  variables {
    aws_secret_name_prefix = ""
  }

  expect_failures = [var.aws_secret_name_prefix]
}

# Values written into user-data heredocs must not carry a newline or shell text.
run "refuses_newline_in_user_data_values" {
  command = plan

  variables {
    vault_addr           = "https://vault.example.com:8200\nEOF\nrm -rf /"
    vault_namespace      = "admin/kv-sync-poc\nX=1"
    vault_iam_server_id  = "vault.example.com\n"
    vault_iam_sts_region = "us-east-1\nX=1"
    aws_cli_image        = "public.ecr.aws/aws-cli/aws-cli:2.22.0\n"
    region               = "ap-southeast-2\n"
    aws_secret_name      = "vault/x\n"
  }

  expect_failures = [
    var.vault_addr,
    var.vault_namespace,
    var.vault_iam_server_id,
    var.vault_iam_sts_region,
    var.aws_cli_image,
    var.region,
    var.aws_secret_name,
  ]
}

run "refuses_shell_text_in_namespace" {
  command = plan

  variables {
    vault_namespace = "admin/$(id)"
  }

  expect_failures = [var.vault_namespace]
}

run "sync_user_boundary_and_policies" {
  command = apply

  variables {
    sync_user_name                     = "custom-sync-user"
    sync_user_permissions_boundary_arn = "arn:aws:iam::111122223333:policy/Boundary"
    sync_user_policy_arns              = ["arn:aws:iam::111122223333:policy/Boundary"]
  }

  assert {
    condition     = aws_iam_user.sync[0].name == "custom-sync-user" && output.sync_principal == "custom-sync-user"
    error_message = "sync_user_name must name the sync user and the output."
  }
  assert {
    condition     = aws_iam_user.sync[0].permissions_boundary == "arn:aws:iam::111122223333:policy/Boundary"
    error_message = "The permissions boundary must be set on the sync user."
  }
  assert {
    condition     = length(aws_iam_user_policy_attachment.sync) == 1 && aws_iam_user_policy_attachment.sync["arn:aws:iam::111122223333:policy/Boundary"].user == "custom-sync-user"
    error_message = "Each extra managed policy must be attached to the sync user."
  }
  assert {
    condition     = jsondecode(aws_iam_user_policy.sync[0].policy).Statement[0].Resource == ["arn:aws:secretsmanager:ap-southeast-2:111122223333:secret:vault/app/*"]
    error_message = "The scoped inline sync policy must still be added."
  }
}

run "none_creates_no_sync_identity" {
  command = apply

  variables {
    sync_auth             = "none"
    sync_user_policy_arns = ["arn:aws:iam::111122223333:policy/Boundary"]
  }

  assert {
    condition = alltrue([
      length(aws_iam_user.sync) == 0,
      length(aws_iam_user_policy.sync) == 0,
      length(aws_iam_user_policy_attachment.sync) == 0,
      length(aws_iam_role.sync) == 0,
      length(aws_iam_openid_connect_provider.vault) == 0,
    ])
    error_message = "none mode creates no sync user, role, OIDC provider or policy."
  }
  assert {
    condition     = output.sync_principal == null
    error_message = "In none mode sync_principal is null."
  }
}

run "refuses_bad_sync_user_inputs" {
  command = plan

  variables {
    sync_user_name                     = "bad name with spaces"
    sync_user_permissions_boundary_arn = "Boundary"
    sync_user_policy_arns              = ["not-an-arn"]
  }

  expect_failures = [
    var.sync_user_name,
    var.sync_user_permissions_boundary_arn,
    var.sync_user_policy_arns,
  ]
}

# The default gives the app, Postgres and the OS package cache room to run. 2 GiB ran out of memory.
run "default_instance_type_has_4_gib" {
  command = plan

  assert {
    condition     = aws_instance.app.instance_type == "t3.medium"
    error_message = "The default instance type should be t3.medium (4 GiB)."
  }
}

run "instance_type_is_overridable" {
  command = plan

  variables {
    instance_type = "t3.large"
  }

  assert {
    condition     = aws_instance.app.instance_type == "t3.large"
    error_message = "instance_type should flow through to the instance."
  }
}

# app_source_dir: the folder with the app's Containerfile, relative to this terraform folder.
run "app_source_dir_builds_the_bundle" {
  command = plan

  assert {
    condition     = endswith(local.app_source_dir, "/${var.app_source_dir}") && data.archive_file.app.output_size > 0
    error_message = "A relative app_source_dir must be taken from the terraform folder and zipped into the bundle."
  }
}

run "refuses_empty_app_source_dir" {
  command = plan

  variables {
    app_source_dir = " "
  }

  expect_failures = [var.app_source_dir]
}

run "refuses_app_source_dir_without_containerfile" {
  command = plan

  variables {
    app_source_dir = "tests"
  }

  expect_failures = [data.archive_file.app]
}

run "refuses_absolute_app_source_dir_without_containerfile" {
  command = plan

  variables {
    app_source_dir = "/nonexistent-acme-orders-app"
  }

  expect_failures = [data.archive_file.app]
}
