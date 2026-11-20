# Domains and DNS

## Hostname plan

One pattern for every service: `<service>.ambrace.in` in production and
`<service>-dev.ambrace.in` in development.

| Purpose | Production | Development | Status |
|---|---|---|---|
| Backend API | `api.ambrace.in` | `api-dev.ambrace.in` | Certificate requested by `infra/bootstrap` |
| Web app | `app.ambrace.in` | `app-dev.ambrace.in` | Planned (webapp repo) |
| Marketing site | `ambrace.in`, `www.ambrace.in` | — | Existing site, unchanged |

The `-dev` suffix keeps the two environments visibly apart in every URL and CORS
list, keeps every hostname one level under `ambrace.in` (so a single wildcard
certificate `*.ambrace.in` could cover them all later), and extends to new
services (`auth-dev.`, `admin-dev.`) without inventing new names.

Cognito sign-in uses the free AWS-provided domain for now:
`ambrace-dev.auth.ap-south-1.amazoncognito.com` (dev) and
`ambrace.auth.ap-south-1.amazoncognito.com` (prod). The same addresses are
registered in the Google OAuth clients. Users only see it
briefly during Google sign-in. A branded `auth.ambrace.in` can be added later; it
needs a second certificate in `us-east-1`.

## Where DNS lives

`ambrace.in` DNS is hosted at the registrar (nameservers `*.dns-parking.com`),
**not** in Route 53. A Route 53 hosted zone costs $0.50 per month and nothing in
the MVP needs it, so records are added by hand at the registrar. Each API domain
needs two records, added once.

If this becomes a chore, delegate the individual API hostnames (`api.ambrace.in`,
`api-dev.ambrace.in`) to Route 53 with NS records and let Terraform manage them; nothing else changes.

## Records to create, per environment

### 1. Certificate validation record (after the bootstrap apply)

`infra/bootstrap` requests the certificate and prints the record ACM wants:

```powershell
terraform output api_certificate_validation_records
```

It looks like this (values differ per certificate):

| Type | Name | Value |
|---|---|---|
| CNAME | `_3f2a….api-dev.ambrace.in.` | `_9c1b….acm-validations.aws.` |

At the registrar's DNS panel:

- Type `CNAME`.
- Name: most panels want it **relative to the domain and without the trailing
  dot**, e.g. `_3f2a….api-dev`. If the panel shows `…api-dev.ambrace.in.ambrace.in`
  after saving, the domain was doubled; remove the `.ambrace.in` suffix.
- Value: paste as printed; drop the trailing dot only if the panel rejects it.
- TTL: default.

Leave this record in place permanently. ACM renews the certificate
automatically for as long as it is in use and this record stays in place. ACM
gives up on a new request after 72 hours, so add the record soon after the
bootstrap apply.

Check it has been issued (usually within 30 minutes):

```powershell
aws acm list-certificates --profile ambrace-dev --region ap-south-1 --query "CertificateSummaryList[].[DomainName,Status]" --output table
```

The status must be `ISSUED` before the application stack can attach the domain.

If it stays `PENDING_VALIDATION` for hours, check that the domain has no `CAA`
record that excludes Amazon. If CAA records exist, add
`ambrace.in. CAA 0 issue "amazon.com"`.

### 2. API record (after the first application deploy)

The application stack creates the API Gateway custom domain and outputs its
target. Add:

| Type | Name | Value |
|---|---|---|
| CNAME | `api-dev` (dev) / `api` (prod) | `d-xxxxxxxxxx.execute-api.ap-south-1.amazonaws.com` |

Then verify:

```powershell
nslookup api-dev.ambrace.in
```

```powershell
curl.exe -s https://api-dev.ambrace.in/health
```

## Order of operations

1. Apply `infra/bootstrap` (admin, CLI). The certificate is requested.
2. Add record 1 at the registrar. Wait for `ISSUED`.
3. Deploy `infra/app` through GitHub Actions. The API custom domain is created.
4. Add record 2 at the registrar.
5. The API answers on its own domain.

Until step 4 the API is still reachable on its default
`https://<api-id>.execute-api.ap-south-1.amazonaws.com` URL, so development is
never blocked on DNS.
