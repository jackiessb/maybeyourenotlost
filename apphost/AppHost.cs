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

builder.Build().Run();