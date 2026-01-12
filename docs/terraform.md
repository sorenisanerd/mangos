# Terraform

Mangos uses Terraform to bootstrap and manage Consul, Nomad, and Vault.

Refer to [upstream documentation](https://developer.hashicorp.com/terraform/language/values/variables) for how to define variables for Terraform.

## Available variables

`admin_users`: A map of admin usernames to bcrypt-hashed passwords.

Example:

This would create a user `foo` with password `bar`.
```hcl
admin_users = {
  foo = "$2y$10$AG67OR.v0dzi5UOcpRW8hOLSHSDeW3MVJh.g/2hnf/wJak9dAbyde"}
}
```

You can generate bcrypt-hashed passwords using the `htpasswd` command from the `apache2-utils` package:

```bash
htpasswd -nbB "" yourpasswordhere | cut -d':' -f2
```
