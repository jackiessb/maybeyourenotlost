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

### 6. Crash #4 (current blocker) — `password authentication failed for user "app"`

```
F Npgsql.PostgresException (0x80004005): 28P01: password authentication
  failed for user "app"
```

A token is now being sent, but Postgres rejects it. This is an
**infrastructure mismatch**, not a code bug:

- Connection strings for both APIs use `Username=app` — Aspire's default
  admin username, generated for the *password-based* admin login Aspire
  normally provisions.
- But `az deployment group list -g rg-dev` shows a `postgres-roles`
  deployment (the only one that ever ran) that created exactly **one**
  Entra-linked Postgres role: the shared user-assigned managed identity
  `mi-yudlalf6hmivo` (object id `92057908-3b71-4cc4-81b0-8bf317251291`),
  which is also the server's sole registered Entra admin
  (`az postgres flexible-server microsoft-entra-admin list`).
- No role named `app` was ever created as an Entra principal. And since
  `passwordAuth` is disabled server-wide, the old password credential for
  `app` (if one was ever generated) can't be used either. `app` is an
  orphaned identity — valid for neither auth path.

## Chosen fix: create an Entra-linked Postgres role named `app`

Decision made with the user: keep the server passwordless (no security
posture change) and create the missing role, rather than re-enabling password
auth or repointing the app at the admin identity (`mi-yudlalf6hmivo`) directly
(which would run the app with admin-level DB privileges — not least-privilege).

This makes `app` a **second** Entra principal on the server, mapped to the
*same* managed identity object id that the containers already authenticate
as, but registered as an ordinary (non-admin) database role. The app code
already expects `Username=app` and already sends a valid Entra token for that
managed identity — once the role exists and has the right grants, the
existing code should just work with no further changes.

### SQL to run (as an admin identity), once against the server

```sql
-- Registers "app" as a Postgres role backed by the managed identity's AAD
-- object id. 'service' marks it as a service principal (not a user account).
SELECT * FROM pgaadauth_create_principal_with_oid(
  'app', '92057908-3b71-4cc4-81b0-8bf317251291', 'service', false, false);

-- The app needs to create tables via EF Core migrations (CREATE TABLE on
-- first startup) and read/write them afterward, in both databases.
GRANT ALL PRIVILEGES ON DATABASE encouragement TO "app";
GRANT ALL PRIVILEGES ON DATABASE contacts TO "app";

-- On Postgres 15+, CREATE on the public schema is no longer granted to
-- PUBLIC by default, so this needs to be explicit per database:
\c encouragement
GRANT CREATE, USAGE ON SCHEMA public TO "app";
\c contacts
GRANT CREATE, USAGE ON SCHEMA public TO "app";
```

(Simplest alternative to the schema grants: `ALTER DATABASE encouragement
OWNER TO "app";` / same for `contacts` — makes `app` the owner outright,
which is safe here since neither database has any tables yet. Either
approach works; ownership is less to maintain if more services are added
later.)

### How this SQL was going to be run

Running SQL against Postgres requires connecting as an existing admin.
Steps taken so far:

1. **Temporarily added `memjkt@gmail.com` as an Entra admin** on
   `postgres-yudlalf6hmivo` via
   `az postgres flexible-server microsoft-entra-admin create` — this is
   still in place and **should be removed** once the role is created:
   ```sh
   az postgres flexible-server microsoft-entra-admin delete \
     -g rg-dev -s postgres-yudlalf6hmivo \
     --object-id 55735d7a-16f2-48c2-8f6c-e7e32181ccd0 --yes
   ```
2. Tried connecting from the local machine with a throwaway
   `docker run postgres:16 psql ...` using an Entra access token
   (`az account get-access-token --resource
   https://ossrdbms-aad.database.windows.net`) as the password. This hung —
   the server firewall only has an `AllowAllAzureIps` rule, which does not
   cover a local/home IP.
3. Considered adding a temporary firewall rule for the local IP — this was
   blocked by the coding assistant's own permission policy (opening public
   DB access is treated as a sensitive action requiring explicit approval),
   so it was not done.
4. Was about to instead exec into the already-running, healthy `frontend`
   container app (`az containerapp exec -g rg-dev -n frontend ...`) to run
   `psql` from *inside* the Container Apps environment, where traffic is
   already allowed by the existing `AllowAllAzureIps` firewall rule — no
   firewall change needed. This was interrupted before completion.

### Remaining steps to actually finish this

1. Get a `psql` (or any Postgres client) session running from *inside* Azure
   (already-allowed network path), authenticated as the `mi-yudlalf6hmivo`
   admin identity or as `memjkt@gmail.com` (temp admin, still active). Options:
   - `az containerapp exec` into the running `frontend` replica and run
     `psql` from there if a client is available in that image, or
   - spin up a short-lived Azure Container Apps Job (or `az container` /ACI)
     using the `postgres:16` image with the managed identity attached, run
     the SQL, then delete the job.
2. Run the SQL block above.
3. Redeploy (or just wait — the running containers already have the correct
   code from the last `azd deploy`; they'll succeed on their next restart
   attempt in the crash-loop backoff cycle, but a fresh `azd deploy` /
   `az containerapp revision restart` is cleaner to verify immediately).
4. Confirm both `encouragement-api` and `contacts-api` come up healthy
   (`az containerapp replica list`).
5. Clean up: remove the temporary Entra admin (`memjkt@gmail.com`) added in
   step 1 above.

## Code changes made so far (already committed to working tree, not yet needing further changes)

- `backend/encouragement-api/Program.cs`, `backend/contacts-api/Program.cs`:
  connection string now includes `Gss Encryption Mode=Disable;Ssl Mode=Require`;
  both build an explicit `NpgsqlDataSource` with `UsePeriodicPasswordProvider`
  backed by `DefaultAzureCredential`, wired into EF Core via
  `configureDbContextOptions: options => options.UseNpgsql(dataSource)`.
- `backend/encouragement-api/encouragement-api.csproj`,
  `backend/contacts-api/contacts-api.csproj`: added
  `PackageReference Include="Azure.Identity" Version="1.21.0"`.

No further app-code changes should be needed — the remaining work is purely
on the Postgres role/grants side, per "Remaining steps" above.
