# a14 — Quiz App with Azure Application Gateway + WAF

## What this is
Flask-based quiz app (cloned from a11-Quiz-App-PostgreSQL) deployed on Azure with:
- **Application Gateway WAF_v2** handling SSL termination and WAF protection
- **Azure PostgreSQL Flexible Server** (private, VNet-integrated)
- **Azure Key Vault** for all secrets — no sensitive values in code
- **VM with public IP** for SSH only — web traffic goes through App Gateway

## Architecture

```
Internet
   │
   ▼
Application Gateway (WAF_v2)        ← public IP: AGW IP (point DNS here)
  - SSL termination (TLS cert from Key Vault)
  - HTTP → HTTPS redirect
  - OWASP 3.2 WAF in Prevention mode
  - Health probe on /login
  - Autoscaling 1-3 instances
   │ HTTP port 80
   ▼
Ubuntu VM (Standard_D2as_v7)        ← public IP: VM IP (for SSH only)
  - nginx (HTTP only, port 80)
  - gunicorn (port 5000)
  - Flask app with ProxyFix middleware
   │
   ▼
PostgreSQL Flexible Server (private, VNet-integrated)
```

## Subnets
| Subnet | CIDR | Purpose |
|---|---|---|
| subnet-app | 10.0.1.0/24 | VM |
| subnet-postgres | 10.0.2.0/24 | PostgreSQL (delegated) |
| subnet-agw | 10.0.3.0/24 | Application Gateway |

## Key Vault secrets required
All secrets live in `vault-test-subscription` (resource group `Vault_RG`):

| Secret Name | Type | Description |
|---|---|---|
| `quiz-entra-tenant-id` | Secret | Entra tenant ID |
| `quiz-entra-client-id` | Secret | Entra client ID |
| `quiz-entra-client-secret` | Secret | Entra client secret |
| `quiz-admin-password` | Secret | VM admin password |
| `quiz-flask-secret-key` | Secret | Flask secret key |
| `quiz-db-password` | Secret | PostgreSQL password |
| `quiz-agw-tls` | **Certificate** | TLS cert for App Gateway (PFX format) |

### Converting Let's Encrypt PEM cert to PFX for App Gateway
```bash
openssl pkcs12 -export \
  -out /tmp/quiz-agw.pfx \
  -inkey /path/to/privkey.pem \
  -in /path/to/fullchain.pem \
  -passout pass:yourpassword

az keyvault certificate import \
  --vault-name vault-test-subscription \
  --name quiz-agw-tls \
  --file /tmp/quiz-agw.pfx \
  --password yourpassword
```

## Deploy

```bash
git clone https://github.com/my-claude-code/a14-Quiz-App-AppGateway.git
cd a14-Quiz-App-AppGateway
terraform init
terraform apply
```

No `terraform.tfvars` needed — all secrets come from Key Vault automatically.

## After deploy

1. **Point DNS** → `aztest.dnsabr.com` to the **AGW public IP** (not the VM IP)
2. **Add redirect URI** in Entra app registration: `https://aztest.dnsabr.com/auth/callback`
3. **Watch VM setup**: `ssh ivansto@<vm-ip> 'tail -f /var/log/app-setup.log'`
4. **Import question data**:
```bash
ssh ivansto@<vm-ip>
cd /opt/quiz-app && source venv/bin/activate
for f in data/english/*.json data/french/*.json data/defender_pam/*.json; do
    python utils/import_questions.py "$f"
done
```

## Important notes
- DNS A record must point to the **App Gateway IP**, not the VM IP
- VM IP is for SSH only
- App Gateway takes ~10 minutes to provision
- ProxyFix is enabled in the Flask app so HTTPS URLs generate correctly behind the proxy
- The cert in Key Vault (`quiz-agw-tls`) must be a **Certificate object** (PFX), not a Secret
- VM admin username is hardcoded as `ivansto`
