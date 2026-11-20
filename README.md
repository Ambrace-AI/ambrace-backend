# Ambrace Backend

FastAPI service behind the Ambrace AI viva (oral assessment) product. It starts a
viva session, mints a short-lived, constrained Gemini Live token for the browser,
and stores the session and its result. The browser talks to Gemini directly; this
service never proxies audio.

Ported from the Veenoe prototype. The viva logic (prompt, token constraints,
session lifecycle) is unchanged.

## How it runs

| Piece | Choice |
|---|---|
| Runtime | AWS Lambda, Python 3.13, arm64, zip package |
| HTTP | API Gateway HTTP API → Lambda Web Adapter → uvicorn |
| Data | DynamoDB, one table per environment (`ambrace-<env>-sessions`) |
| Secrets | SSM Parameter Store SecureString under `/ambrace/<env>/` |
| Auth | Amazon Cognito access tokens, verified in the app |
| Region | `ap-south-1` (Mumbai), one AWS account per environment |

## Layout

```
app/
  api/            HTTP routes
  core/auth/      Cognito token verification and FastAPI auth dependencies
  core/           settings and SSM runtime configuration
  services/       viva lifecycle, Gemini Live token and prompt construction
  db/             DynamoDB repository
infra/
  bootstrap/      applied once per account by an admin (state, GitHub OIDC, deploy role)
  app/            everything else, applied only by GitHub Actions
scripts/          Lambda packaging
tests/            pytest suite (no AWS access needed)
docs/             Gemini Live contract, QA notes, domains and DNS
```

## Authentication status

Protected routes require a Cognito **access token** as `Authorization: Bearer …`.
The token's signature, expiry, issuer, `token_use` and `client_id` are checked.

Each environment has its own Cognito user pool (`infra/app/cognito.tf`). People
sign in with an email and password or with Google, and the web app sends the
resulting access token to this API.

- **Cost:** the pool uses the Lite feature plan (free up to 10,000 monthly
  active users, Google sign-ins included), Cognito's built-in email sender
  (50 emails a day per AWS account) and no MFA text messages.
- **Google credentials:** the deployment creates one SecureString parameter,
  `/ambrace/<env>/google_oauth`, with a placeholder. An operator replaces its
  value with the JSON `{"client_id":"...","client_secret":"..."}` from the
  Google OAuth client and then **runs the deployment again**, which passes the
  values to Cognito. Until then Google sign-in does not work and the deployment
  log shows a warning; email and password sign-in works regardless. A malformed
  value stops the deployment with a clear error. Rotation is the same two steps.
- **Not linked:** the same email used once with Google and once with a password
  is two separate accounts for now.

When run locally without `COGNITO_USER_POOL_ID` and `COGNITO_APP_CLIENT_ID`, the
API fails closed: `/` and `/health` work, every protected route returns `401`.

## Local development

Requires [uv](https://docs.astral.sh/uv/). uv installs Python 3.13 and the exact
dependency versions recorded in `uv.lock`; there is no separate install step.

```powershell
Copy-Item .env.example .env
```

Fill in `.env`, then:

```powershell
uv run uvicorn app.main:app --reload --port 8080
```

Dependencies are declared in `pyproject.toml`. After changing them, run
`uv lock` and commit `uv.lock`.

`.env.example` points at DynamoDB Local on port 8000. Leave
`AMBRACE_SSM_PARAMETER_PREFIX` unset locally so settings come from `.env`.

## Tests and checks

```powershell
uv run python scripts/build_lambda.py
```

```powershell
uv run pytest
```

The packaging tests inspect the built zip, so build first.

Code quality (the same commands CI runs; versions are locked in `uv.lock`):

```powershell
uv run ruff format .
```

```powershell
uv run ruff check --fix .
```

```powershell
uv run mypy
```

Terraform checks need no AWS credentials:

```powershell
terraform fmt -check -recursive infra
```

```powershell
terraform -chdir=infra/app init -backend=false
```

```powershell
terraform -chdir=infra/app test
```

The same steps run in GitHub Actions on every pull request (`checks.yml`), which
also lints Terraform with TFLint and the workflow files with actionlint. Two
scans are advisory and do not block a merge yet: Trivy (Terraform
misconfigurations) and zizmor (workflow security).

## Deploying

Nothing is deployed from a laptop. GitHub Actions assumes an AWS role through
OIDC; there are no stored AWS keys.

| Workflow | Trigger | Effect |
|---|---|---|
| `checks.yml` | every pull request, pushes to `master` | tests, package, Terraform checks |
| `deploy-dev.yml` | manual (PLAN / APPLY), from `master` or an `Ambrace-*` branch | deploys to the dev account |
| `deploy-prod.yml` | manual (PLAN / APPLY), from the `release` branch only | deploys to the prod account after a reviewer approves |

Nothing deploys on a push or a merge. `_deploy.yml` holds the steps both
pipelines share, so dev and prod are deployed the same way.

**Branches:** work lands on `master` through pull requests and is deployed to
dev by hand. To release, merge `master` into `release` and run
`deploy-prod.yml` from `release`. Production runs the code *and the workflow
files* as they exist on `release`, so a pipeline change on `master` cannot
reach production until it is promoted.

Each deploy runs the tests against the exact artifact, plans, refuses any plan
that deletes or replaces a resource, applies, then smoke-tests the live API
(health, database, 401 on anonymous and forged callers, CORS) and confirms a
second plan is empty.

The one-time account setup is in [infra/bootstrap/README.md](infra/bootstrap/README.md).

### After the first deploy of an environment

1. **Set the real Gemini API key.** Terraform creates
   `/ambrace/<env>/google_api_key` with a placeholder. Replace the value in the
   AWS console (Systems Manager → Parameter Store), keeping type SecureString.
   Lambda reads it at cold start, so redeploy or wait for a new instance.
2. **Add the API DNS record** shown in the deploy log
   ([docs/domains-and-dns.md](docs/domains-and-dns.md)). Until then the API is
   reachable on its default `execute-api` URL.

## Configuration

| Variable | Set by | Purpose |
|---|---|---|
| `DYNAMODB_TABLE_NAME` | Terraform | sessions table |
| `AMBRACE_SSM_PARAMETER_PREFIX` | Terraform | where to read secrets; unset locally |
| `GOOGLE_API_KEY` | SSM (`google_api_key`) | Gemini API key |
| `GEMINI_LIVE_MODEL` | Terraform | Gemini Live model name |
| `VIVA_SESSION_DURATION_MINUTES` | Terraform | 5, 10 or 15 |
| `CORS_ORIGINS` | Terraform | exact browser origins, comma-separated, no wildcards |
| `COGNITO_USER_POOL_ID`, `COGNITO_APP_CLIENT_ID` | Terraform (from the user pool it creates) | set together, or both empty (fail closed) |

## Privacy

Candidate audio never reaches this service. Transcripts and prompts are never
logged; logs carry event names and safe metadata only.
