# 504 on `/encouragements` — investigation notes

Started from: `POST https://love.maybeyourenotlost.com/encouragements` returning
`504 Gateway Timeout` in the deployed Azure environment (`rg-dev`).

## Symptom chain and fixes applied so far

The 504 turned out to be four stacked issues. Each fix revealed the next one
underneath it. Both `backend/encouragement-api` and `backend/contacts-api` are
affected identically (same code shape, same Postgres server), even though only
`/encouragements` was reported — `contacts-api` was crash-looping too.

### 1. Reverse proxy — ruled out

The frontend's YARP reverse proxy config (wired manually in `apphost/AppHost.cs`
to work around an Aspire bug where `PublishAsStaticWebsite` always writes its
route/cluster under the fixed id `"api"`) was checked against the live
container's env vars and found to be correct and symmetric with the
auto-generated `/contacts` route. Not the problem.

### 2. Root cause of the 504 itself: both API containers were crash-looping

`az containerapp replica list` showed `encouragement-api` and `contacts-api`
both stuck in `CrashLoopBackOff`. With no ready replica, the reverse proxy has
nothing to forward to and times out → 504. Everything after this was about why
the containers were crashing on startup (in `db.Database.Migrate()`).

### 3. Crash #1 — missing GSSAPI library → unencrypted connection attempt

```
F Cannot load library libgssapi_krb5.so.2
F Npgsql.PostgresException: 28000: no pg_hba.conf entry for host "...",
  user "app", database "encouragement", no encryption
```

The container image lacks `libgssapi_krb5.so.2`, so Npgsql's GSS-encryption
negotiation throws, and the connection falls through to a plaintext attempt.
Azure Postgres Flexible Server has `require_secure_transport = on`, so
pg_hba.conf rejects it outright.

**Fix applied** (`Program.cs`, both APIs): append
`Gss Encryption Mode=Disable` to the connection string. GSS is for Kerberos
auth and irrelevant here.

### 4. Crash #2 — disabling GSS also skipped SSL negotiation

After fix #3, the same "no encryption" pg_hba rejection persisted, just
without the library-load error. Disabling GSS in this Npgsql version appears
to skip past the SSL negotiation step too, instead of just falling through to
it.

**Fix applied**: also append `Ssl Mode=Require` explicitly, so TLS is forced
regardless of the GSS setting.

### 5. Crash #3 — no password provided

```
F Npgsql.NpgsqlException: No password has been provided but the backend
  requires one (in SASL/SCRAM-SHA-256-PLUS)
```

This confirmed TLS was now negotiating correctly (got past encryption into
the SASL auth step). The real issue: this Postgres server has
`passwordAuth: Disabled` / `activeDirectoryAuth: Enabled` (Entra ID-only), but
nothing in the app was acquiring an Entra token to use as the password.
`Aspire.Npgsql.EntityFrameworkCore.PostgreSQL` does **not** do this
automatically — confirmed by inspecting the assembly (no
Credential/TokenCredential/PasswordProvider symbols in it).

**Fix applied**: added `Azure.Identity` package reference to both API
projects. In `Program.cs`, built an explicit `NpgsqlDataSource` via
`NpgsqlDataSourceBuilder.UsePeriodicPasswordProvider`, which calls
`DefaultAzureCredential` to fetch a fresh Entra token (scope
`https://ossrdbms-aad.database.windows.net/.default`) from the container's
managed identity every ~55 minutes, then wired it into EF Core with
`options.UseNpgsql(dataSource)`.

### 6. Crash #4 — `password authentication failed for user "app"`

```
F Npgsql.PostgresException (0x80004005): 28P01: password authentication
  failed for user "app"
```

A token was now being sent, but as the wrong Postgres role. **The earlier
reading of this — that `app` came from Aspire's default admin username and was
an orphaned identity — was wrong.** Nothing in the app or the infrastructure
ever set `Username=app`:

- The generated bicep emits
  `output connectionString string = 'Host=${postgres.properties.fullyQualifiedDomainName}'`
  — host only, **no username, no password**. `.azure/dev/.env` confirms it:
  `POSTGRES_CONNECTIONSTRING="Host=postgres-yudlalf6hmivo.postgres.database.azure.com"`.
  So `ConnectionStrings__encouragement` is just `Host=…;Database=encouragement`.
- With no `Username` in the connection string, Npgsql infers one: `PGUSER`,
  then Kerberos detection, then `Environment.UserName` (it throws
  "No username could be found" only if all fail).
- The .NET container images create and run as a non-root OS user literally
  named **`app`** (`APP_UID=1654`, `useradd … app` in
  `dotnet/dotnet-docker` `runtime-deps`). So `Environment.UserName` is `app`.

`app` was never a Postgres role, an Entra principal, or an Aspire default — it
is the container's OS user leaking into the connection string. The Entra token
itself was fine; it was just being presented as the wrong role name.

The username is left blank on purpose: Aspire expects the *client* integration
to fill it in from the token, because the correct role name depends on which
managed identity the token was issued to.

## Root cause: the wrong Npgsql client integration

`Aspire.Npgsql.EntityFrameworkCore.PostgreSQL` is the plain integration and
knows nothing about Entra — correctly observed earlier. The Entra-aware
sibling is a separate package:

**`Aspire.Azure.Npgsql.EntityFrameworkCore.PostgreSQL`** → `AddAzureNpgsqlDbContext<T>()`

Its `ConfigureEntraIdAuthentication` (in Aspire's
`ManagedIdentityTokenCredentialHelpers`) does two things, each only when the
connection string leaves that field empty:

1. **Username** — acquires a token for `https://management.azure.com/.default`
   (the management scope, because that token carries identity names), decodes
   the JWT payload and reads `xms_mirid`, whose tail segment after
   `providers/Microsoft.ManagedIdentity/userAssignedIdentities/` is the
   identity's name. Falls back to `upn`, `preferred_username`, `unique_name`.
2. **Password** — registers `UsePasswordProvider` returning a fresh
   `https://ossrdbms-aad.database.windows.net/.default` token per physical
   connection (no caching; refreshed on expiry).

For this environment `xms_mirid` resolves to **`mi-yudlalf6hmivo`**, which is
exactly the Postgres role that already exists — the sole registered Entra
admin on the server, backed by object id `92057908-3b71-4cc4-81b0-8bf317251291`,
which is the principal id of the user-assigned identity already attached to
every container app (`AZURE_CLIENT_ID=1bc1d4d6-7bac-44ea-82a8-d8ffded36835`).

Because both blocks are skipped when the connection string already carries a
username/password, the same call is safe in local `RunAsContainer` dev, where
Aspire supplies `Username=postgres;Password=…`.

**No SQL, no firewall rule, no temporary Entra admin, and no infrastructure
change is required.** The role the app needs already exists; the app was
simply never asking for it by name.

## Fix applied

- Both `.csproj`: replaced `Aspire.Npgsql.EntityFrameworkCore.PostgreSQL` with
  `Aspire.Azure.Npgsql.EntityFrameworkCore.PostgreSQL` (13.4.6). The explicit
  `Azure.Identity` reference is **kept and is load-bearing** — the Aspire Azure
  package builds a `DefaultAzureCredential` but only depends on `Azure.Core`,
  so without a direct reference `Azure.Identity.dll` is not copied to the
  output and the credential fails to load at runtime. (Verified: it is absent
  from `deps.json` when the reference is removed.)
- Both `Program.cs`: deleted the hand-rolled `NpgsqlDataSourceBuilder` /
  `UsePeriodicPasswordProvider` / `DefaultAzureCredential` block — which
  supplied the password but not the username, hence the failure — and replaced
  `AddNpgsqlDbContext` with `AddAzureNpgsqlDbContext`.
- `Ssl Mode=Require` is now applied only when not in Development. The local
  Aspire Postgres container serves plaintext, so forcing TLS unconditionally
  (as the previous fix did) would have broken `aspire run` locally.
  `Gss Encryption Mode=Disable` stays unconditional: the base image genuinely
  ships no krb5 libraries (`runtime-deps` installs only `libc6`, `libgcc-s1`,
  `libicu74`, `libssl3t64`, `libstdc++6`, `tzdata`), so the finding in §3 was
  correct.

`dotnet build` succeeds and `Azure.Identity.dll` is present in both outputs.

## Remaining steps

1. `azd deploy` (or `az containerapp revision restart`) both APIs.
2. Confirm both replicas reach Running (`az containerapp replica list`) and
   that `POST /encouragements` returns 201 rather than 504.
3. Watch for one possible follow-on: `db.Database.Migrate()` needs `CREATE` on
   `public`. `mi-yudlalf6hmivo` is a member of `azure_pg_admin` so this should
   pass, but if it fails with `permission denied for schema public` (Postgres
   16 no longer grants `CREATE` on `public` to `PUBLIC`), run
   `GRANT CREATE, USAGE ON SCHEMA public TO "mi-yudlalf6hmivo";` in each
   database.

## Not done: least privilege

The app now connects as the server's Entra **admin**. That is Aspire's shipped
default — its generated `postgres-roles` module registers the app's identity as
`flexibleServers/administrators`, and there is no non-admin role provisioning
in the box — but it is not least privilege. Two ways to tighten it later, both
requiring a one-off SQL session from inside Azure (a short-lived Container Apps
job or ACI running `postgres:16` with `mi-yudlalf6hmivo` attached reaches the
server through the existing `AllowAllAzureIps` rule — no firewall change and no
personal admin grant needed):

- **Cheap:** create a non-admin role mapped to the *same* object id, e.g.
  `pgaadauth_create_principal_with_oid('app', '92057908-…', 'service', false, false)`,
  grant it only what each database needs, and pin the role explicitly with
  `settings.ConnectionString += ";Username=app"` — `AddAzureNpgsqlDbContext`
  honours an explicit username and only infers when it is blank. Verify the
  duplicate-oid mapping with `SELECT * FROM pgaadauth_list_principals(false);`
  before relying on it.
- **Proper:** give each API its own user-assigned identity
  (`AddAzureUserAssignedIdentity` / `WithAzureUserAssignedIdentity`, both
  present in Aspire.Hosting.Azure 13.4.6), register each as a non-admin
  Postgres role, and grant it only its own database. Username inference then
  resolves per-service with no connection-string overrides.

## Superseded

The earlier plan — creating an Entra-linked role named `app`, and the hunt for
a network path to run that SQL (temp Entra admin for `memjkt@gmail.com`,
firewall rule for a home IP, `az containerapp exec` into the frontend) — was
built on the incorrect `Username=app` diagnosis and is no longer needed. The
temporary Entra admin grant was already removed; no cleanup is outstanding.
