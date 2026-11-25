# Acme Orders web front end: read the database password, nothing else.
# app/data/db holds the versions, app/metadata/db the version list.
path "app/data/db" {
  capabilities = ["read"]
}

path "app/metadata/db" {
  capabilities = ["read"]
}
