using Azure.Provisioning;
using Azure.Provisioning.AppContainers;
using Azure.Provisioning.Expressions;
using Azure.Provisioning.PostgreSql;
using Azure.Provisioning.Resources;
using Microsoft.Extensions.Hosting;

var builder = DistributedApplication.CreateBuilder(args);

// WithAzdResourceNaming keeps the names of the resources azd already provisioned.
builder.AddAzureContainerAppEnvironment("cae").WithAzdResourceNaming();

var postgres = builder.AddAzurePostgresFlexibleServer("postgres")
    .RunAsContainer(container => container.WithPgAdmin())
    .ConfigureInfrastructure(infrastructure =>
    {
        // Aspire pins the server to availability zone "1" by default. Zone numbers are
        // logical per subscription -- zone "1" in one subscription is not the same
        // physical zone as in another, and capacity differs -- so a pinned zone does not
        // survive a move between subscriptions. It surfaces as `SkuNotAvailable` on an
        // SKU the region genuinely offers, which sends you looking at the wrong thing.
        // Empty means "let Azure choose".
        var server = infrastructure.GetProvisionableResources()
            .OfType<PostgreSqlFlexibleServer>()
            .Single();

        server.AvailabilityZone = "";
    });

var encouragementDb = postgres.AddDatabase("encouragement");
var contactsDb = postgres.AddDatabase("contacts");

var customDomain = builder.AddParameter("customDomain");
var certificateName = builder.AddParameter("certificateName");

var encouragementApi = builder.AddProject<Projects.encouragement_api>("encouragement-api")
    .WithReference(encouragementDb)
    .WaitFor(encouragementDb)
    .PublishAsAzureContainerApp((infrastructure, app) =>
    {
        app.Template.Scale.MinReplicas = 1;
        app.Template.Scale.MaxReplicas = 3;
    });

var contactsApi = builder.AddProject<Projects.contacts_api>("contacts-api")
    .WithReference(contactsDb)
    .WaitFor(contactsDb)
    .PublishAsAzureContainerApp((infrastructure, app) =>
    {
        app.Template.Scale.MinReplicas = 1;
        app.Template.Scale.MaxReplicas = 3;
    });

#pragma warning disable ASPIREJAVASCRIPT001
var frontend = builder.AddJavaScriptApp("frontend", "../frontend", "dev")
    .WithHttpEndpoint(env: "PORT")
    .WithExternalHttpEndpoints()
    .WithReference(encouragementApi)
    .WithReference(contactsApi)
    .WithBuildScript("build")
    .PublishAsStaticWebsite("/contacts", contactsApi)
    .PublishAsAzureContainerApp((infrastructure, app) =>
    {
        app.Template.Scale.MinReplicas = 2;
        app.Template.Scale.MaxReplicas = 10;
        app.ConfigureCustomDomain(customDomain, certificateName);
    });
#pragma warning restore ASPIREJAVASCRIPT001

// The dashboard has no dev environment: it runs locally and deploys to production only.
var includeDashboard = !builder.ExecutionContext.IsPublishMode || builder.Environment.IsProduction();

if (builder.ExecutionContext.IsPublishMode)
{
    var frontendOrigin = builder.AddParameter("frontendOrigin");
    encouragementApi.WithEnvironment("Frontend__Origin", frontendOrigin);
    contactsApi.WithEnvironment("Frontend__Origin", frontendOrigin);

    frontend
        .WithEnvironment("REVERSEPROXY__ROUTES__encouragements__CLUSTERID", "encouragements")
        .WithEnvironment("REVERSEPROXY__ROUTES__encouragements__MATCH__PATH", "/encouragements/{**catch-all}")
        .WithEnvironment("REVERSEPROXY__CLUSTERS__encouragements__DESTINATIONS__destination1__ADDRESS", "https+http://encouragement-api");
}
else
{
    encouragementApi.WithEnvironment("Frontend__Origin", frontend.GetEndpoint("http"));
    contactsApi.WithEnvironment("Frontend__Origin", frontend.GetEndpoint("http"));
}

if (includeDashboard)
{
#pragma warning disable ASPIREJAVASCRIPT001
    var dashboard = builder.AddJavaScriptApp("dashboard", "../dashboard", "dev")
        .WithHttpEndpoint(env: "PORT")
        .WithExternalHttpEndpoints()
        .WithReference(encouragementApi)
        .WithReference(contactsApi)
        .WithBuildScript("build")
        .PublishAsStaticWebsite("/admin/contacts", contactsApi);
#pragma warning restore ASPIREJAVASCRIPT001

    if (builder.ExecutionContext.IsPublishMode)
    {
        var dashboardCustomDomain = builder.AddParameter("dashboardCustomDomain");
        var dashboardCertificateName = builder.AddParameter("dashboardCertificateName");
        var dashboardOrigin = builder.AddParameter("dashboardOrigin");
        var dashboardEntraClientId = builder.AddParameter("dashboardEntraClientId");
        var dashboardEntraTenantId = builder.AddParameter("dashboardEntraTenantId");

        // Key Vault secret URIs, both produced by Terraform (infra/terraform).
        // These are URIs, not secret values -- the values are resolved at runtime by
        // the Container App's managed identity, so they are safe in appsettings.
        var dashboardClientSecretUri = builder.AddParameter("dashboardClientSecretKeyVaultUri");
        var dashboardTokenStoreSasUri = builder.AddParameter("dashboardTokenStoreSasKeyVaultUri");

        encouragementApi.WithEnvironment("Dashboard__Origin", dashboardOrigin);
        contactsApi.WithEnvironment("Dashboard__Origin", dashboardOrigin);

        dashboard
            .WithEnvironment("REVERSEPROXY__ROUTES__encouragements__CLUSTERID", "encouragements")
            .WithEnvironment("REVERSEPROXY__ROUTES__encouragements__MATCH__PATH", "/admin/encouragements/{**catch-all}")
            .WithEnvironment("REVERSEPROXY__CLUSTERS__encouragements__DESTINATIONS__destination1__ADDRESS", "https+http://encouragement-api")
            .PublishAsAzureContainerApp((infrastructure, app) =>
            {
                app.Template.Scale.MinReplicas = 1;
                app.Template.Scale.MaxReplicas = 2;
                app.ConfigureCustomDomain(dashboardCustomDomain, dashboardCertificateName);

                var clientId = dashboardEntraClientId.AsProvisioningParameter(infrastructure);
                var tenantId = dashboardEntraTenantId.AsProvisioningParameter(infrastructure);
                var clientSecretUri = dashboardClientSecretUri.AsProvisioningParameter(infrastructure);
                var tokenStoreSasUri = dashboardTokenStoreSasUri.AsProvisioningParameter(infrastructure);

                const string clientSecretName = "aad-client-secret";
                const string tokenStoreSasName = "tokenstore-sas";

                // Easy Auth resolves both Key Vault references through the app's own
                // identity, so it needs a system-assigned one. Add it rather than replace:
                // Aspire attaches a user-assigned identity for ACR image pull, and
                // clobbering that breaks the deploy's ability to pull the image.
                app.Identity ??= new ManagedServiceIdentity();
                app.Identity.ManagedServiceIdentityType =
                    app.Identity.UserAssignedIdentities.Count > 0
                        ? ManagedServiceIdentityType.SystemAssignedUserAssigned
                        : ManagedServiceIdentityType.SystemAssigned;

                // Both secrets are Key Vault references, not literals: Terraform writes the
                // values into the vault and nothing sensitive passes through Bicep, azd
                // parameters, or CI logs. The URIs are versionless, so a Terraform-driven
                // rotation is picked up without redeploying the app.
                app.Configuration.Secrets.Add(new ContainerAppWritableSecret
                {
                    Name = clientSecretName,
                    KeyVaultUri = clientSecretUri,
                    Identity = "system",
                });

                app.Configuration.Secrets.Add(new ContainerAppWritableSecret
                {
                    Name = tokenStoreSasName,
                    KeyVaultUri = tokenStoreSasUri,
                    Identity = "system",
                });

                // Easy Auth: every request must be signed in with Entra ID. Who may sign in
                // is controlled by "Assignment required" on the app registration's Enterprise
                // Application plus its explicit app role assignments, both managed in
                // infra/terraform/entra.
                //
                // All four of the following are required together, and each one alone fails
                // differently -- see docs/plans/entra-auth-as-code.md:
                //   1. a client secret, so Easy Auth can do a confidential-client code exchange
                //   2. the redirect URI on the app registration's `web` platform (not `spa`),
                //      or the exchange fails with AADSTS9002325 for want of PKCE
                //   3. implicit ID token issuance enabled, or sign-in fails with AADSTS700054
                //   4. an enabled, blob-backed token store -- without it sign-in succeeds and
                //      /.auth/me still 404s, which presents as a login redirect loop
                // Items 2 and 3 live in Terraform; 1 and 4 are below.
                infrastructure.Add(new ContainerAppAuthConfig("dashboardAuth")
                {
                    Parent = app,
                    Name = "current",
                    Platform = new ContainerAppAuthPlatform { IsEnabled = true },
                    GlobalValidation = new ContainerAppGlobalValidation
                    {
                        UnauthenticatedClientAction = ContainerAppUnauthenticatedClientActionV2.RedirectToLoginPage,
                        RedirectToProvider = "azureactivedirectory",
                    },
                    IdentityProviders = new ContainerAppIdentityProvidersConfiguration
                    {
                        AzureActiveDirectory = new ContainerAppAzureActiveDirectoryConfiguration
                        {
                            IsEnabled = true,
                            Registration = new ContainerAppAzureActiveDirectoryRegistrationConfiguration
                            {
                                ClientId = clientId,
                                ClientSecretSettingName = clientSecretName,
                                OpenIdIssuer = BicepFunction.Interpolate($"https://login.microsoftonline.com/{tenantId}/v2.0"),
                            },
                            Validation = new ContainerAppAzureActiveDirectoryValidationConfiguration
                            {
                                AllowedAudiences = { clientId },
                            },
                        },
                    },
                    Login = new ContainerAppLogin
                    {
                        TokenStore = new ContainerAppTokenStore
                        {
                            IsEnabled = true,
                            AzureBlobStorageSasUrlSettingName = tokenStoreSasName,
                        },
                    },
                });
            });
    }
    else
    {
        encouragementApi.WithEnvironment("Dashboard__Origin", dashboard.GetEndpoint("http"));
        contactsApi.WithEnvironment("Dashboard__Origin", dashboard.GetEndpoint("http"));
    }
}

builder.Build().Run();