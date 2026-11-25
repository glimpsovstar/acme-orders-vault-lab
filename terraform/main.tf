provider "aws" {
  region = var.region

  default_tags {
    tags = var.default_tags
  }
}

locals {
  bundle_key = "acme-orders/app.zip"

  # A relative app_source_dir is taken from this folder, an absolute one as it is.
  app_source_dir = startswith(var.app_source_dir, "/") ? var.app_source_dir : "${path.module}/${var.app_source_dir}"

  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    region          = var.region
    bundle_url      = "s3://${aws_s3_bucket.app.bucket}/${local.bundle_key}"
    aws_cli_image   = var.aws_cli_image
    vault_addr      = var.vault_addr
    vault_namespace = var.vault_namespace
    aws_secret_name = var.aws_secret_name
    iam_server_id   = var.vault_iam_server_id
    iam_sts_region  = var.vault_iam_sts_region
  })
}

data "aws_subnet" "app" {
  id = var.subnet_id
}

# The app source, built into an image on the instance.
data "archive_file" "app" {
  type        = "zip"
  source_dir  = local.app_source_dir
  output_path = "${path.module}/.build/app.zip"
  excludes = [
    ".venv",
    ".venv/**",
    "tests",
    "tests/**",
    ".pytest_cache",
    ".pytest_cache/**",
    "**/__pycache__",
    "**/__pycache__/**",
    "pytest.ini",
    ".env",
    ".env*",
    "**/.env",
    "**/.env*",
    ".lab.env",
    "**/.lab.env",
    "*.pyc",
    "**/*.pyc",
    ".git",
    ".git/**",
    ".gitignore",
    "compose.dev.yaml",
  ]

  lifecycle {
    precondition {
      condition     = fileexists("${local.app_source_dir}/Containerfile")
      error_message = "app_source_dir must be the folder that holds the app's Containerfile, for example ../../acme-orders-vault-demo."
    }
  }
}

resource "aws_s3_bucket" "app" {
  bucket_prefix = "${var.name}-app-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "app" {
  bucket = aws_s3_bucket.app.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "app" {
  bucket = aws_s3_bucket.app.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "app" {
  bucket = aws_s3_bucket.app.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "app" {
  bucket      = aws_s3_bucket.app.id
  key         = local.bundle_key
  source      = data.archive_file.app.output_path
  source_hash = data.archive_file.app.output_base64sha256

  depends_on = [
    aws_s3_bucket_public_access_block.app,
    aws_s3_bucket_server_side_encryption_configuration.app,
  ]
}

resource "aws_security_group" "app" {
  name_prefix = "${var.name}-"
  description = "Acme Orders lab: app and SSH from the operator only"
  vpc_id      = data.aws_subnet.app.vpc_id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "app" {
  security_group_id = aws_security_group.app.id
  description       = "Acme Orders web, plain HTTP"
  ip_protocol       = "tcp"
  from_port         = 8080
  to_port           = 8080
  cidr_ipv4         = var.operator_cidr
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.app.id
  description       = "SSH for the operator"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = var.operator_cidr
}

# Outbound to HCP Vault, AWS APIs and container registries.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.app.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_instance" "app" {
  ami                         = var.image_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.app.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.app.name
  key_name                    = var.ssh_key_name

  user_data                   = local.user_data
  user_data_replace_on_change = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  tags = {
    Name = var.name
  }

  # First boot only. Settings and app updates are applied on the box, see the README.
  lifecycle {
    ignore_changes = [user_data, ami]
  }

  depends_on = [aws_s3_object.app, aws_iam_role_policy.instance]
}
