output "app_url" {
  description = "Acme Orders in a browser. Plain HTTP, reachable only from operator_cidr."
  value       = "http://${aws_instance.app.public_ip}:8080"
}

output "instance_role_arn" {
  description = "Instance role ARN. Bind it in the Vault AWS auth role (bound_iam_principal_arn)."
  value       = aws_iam_role.instance.arn
}

output "aws_secret_name_prefix" {
  description = "Synced secret names must start with this. The instance role can read, and Vault sync can write, only these."
  value       = var.aws_secret_name_prefix
}

output "sync_principal" {
  description = "Who Vault secrets sync acts as: the IAM user name (iam_user), the role ARN (wif), or null (none). Never a key."
  value       = var.sync_auth == "wif" ? aws_iam_role.sync[0].arn : var.sync_auth == "iam_user" ? aws_iam_user.sync[0].name : null
}
