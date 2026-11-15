# Deploying to Azure

The backend runs on **Azure Container Apps**, in the resource group `Nexo`
(Chile Central, the closest region to Peru), and answers at
`https://api.nexo.aurx.pro`.

```
App Nexo ──HTTPS──> api.nexo.aurx.pro (Container Apps ingress, managed certificate)
                         │
                         └─> nexo-api container ──> MongoDB Atlas, SIGMA
```

The image is built **in Azure** (`az acr build`), so Docker is not needed
locally.

## What gets created

| Resource | Name | Approximate cost |
| --- | --- | --- |
| Container registry (Basic) | `nexo<subscription id>` | ~5 USD/month |
| Container Apps environment | `nexo-env` | Its Log Analytics workspace bills per GB of logs |
| Container app (0.5 vCPU, 1 GiB) | `nexo-api` | With `MIN_REPLICAS=0` it scales to zero and mostly fits the monthly free grant |

`MIN_REPLICAS=0` saves credit, but the first request after a quiet period
waits a few seconds while the container starts, and in-memory rate limits
and caches start empty. Use `MIN_REPLICAS=1 deploy/azure/deploy.sh` once the
app is in real use.

## Steps

1. Sign in: `az login`.
2. Copy `env.production.example` to `.env.production` in this folder and fill
   it in. That file is ignored by git and kept out of the Docker build
   context. Generate the keys with `mix phx.gen.secret` and
   `openssl rand -base64 32`.
3. Deploy: `deploy/azure/deploy.sh`. It prints the app's default address and
   its outbound IPs.
4. MongoDB Atlas > Network Access: allow those outbound IPs.
5. Check `https://<default address>/health`.
6. Bind the domain: `deploy/azure/deploy.sh domain`. It shows the two records
   to create in Hostinger (a `CNAME` for `api.nexo` and a `TXT` for
   `asuid.api.nexo`), waits for you, binds the domain with a free managed
   certificate, and sets `ALLOWED_HOSTS` so the API stops answering on any
   other address.

Later deploys are just `deploy/azure/deploy.sh`: it rebuilds the image from
the current commit and updates the app in place.

## Production settings

| Variable | Set by | Purpose |
| --- | --- | --- |
| `MONGODB_URI`, `SECRET_KEY_BASE`, `ADMIN_API_KEY` | `.env.production`, stored as secrets | Required |
| `AUTHORIZED_TEACHERS`, `SYSTEM_ADMINS` | `.env.production`, stored as secrets | Personal data |
| `APP_CHECK_MODE`, `FIREBASE_PROJECT_NUMBER`, `FIREBASE_APP_IDS` | `.env.production` | Only the official app may call the API |
| `FCM_SERVICE_ACCOUNT_JSON` | script, from `deploy/azure/firebase-service-account.json` (gitignored) if present, stored as a secret | Push notifications when a teacher saves grades; off without it |
| `PHX_HOST` | script (`api.nexo.aurx.pro`) | Public host |
| `ALLOWED_HOSTS` | `domain` step | Any other `Host` gets `421` |
| `TRUSTED_PROXIES` | script (private ranges) | Where the real client IP may be read from |

Until Firebase App Check is configured, `APP_CHECK_MODE=enforce` refuses
every request on purpose. Use `monitor` while the app is being updated to
send the token.
