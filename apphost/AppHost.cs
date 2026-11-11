using Azure.Provisioning;
using Azure.Provisioning.AppContainers;
using Azure.Provisioning.Expressions;
using Microsoft.Extensions.Hosting;

var builder = DistributedApplication.CreateBuilder(args);

// WithAzdResourceNaming keeps the names of the resources azd already provisioned.
builder.AddAzureContainerAppEnvironment("cae").WithAzdResourceNaming();

var postgres = builder.AddAzurePostgresFlexibleServer("postgres")
    .RunAsContainer(container => container.WithPgAdmin());

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

                // Easy Auth: every request must be signed in with Entra ID. No client secret is
                // configured, so sign-in uses the ID token flow. Who may sign in is controlled by
                // "Assignment required" on the app registration's Enterprise Application.
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
                                OpenIdIssuer = BicepFunction.Interpolate($"https://login.microsoftonline.com/{tenantId}/v2.0"),
                            },
                            Validation = new ContainerAppAzureActiveDirectoryValidationConfiguration
                            {
                                AllowedAudiences = { clientId },
                            },
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