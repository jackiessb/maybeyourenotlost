var builder = DistributedApplication.CreateBuilder(args);

var postgres = builder.AddAzurePostgresFlexibleServer("postgres")
    .RunAsContainer();

var encouragementDb = postgres.AddDatabase("encouragement");
var contactsDb = postgres.AddDatabase("contacts");

var encouragementApi = builder.AddProject<Projects.encouragement_api>("encouragement-api")
    .WithReference(encouragementDb);
var contactsApi = builder.AddProject<Projects.contacts_api>("contacts-api")
    .WithReference(contactsDb);

#pragma warning disable ASPIREJAVASCRIPT001
var frontend = builder.AddJavaScriptApp("frontend", "../frontend", "dev")
    .WithHttpEndpoint(env: "PORT")
    .WithExternalHttpEndpoints()
    .WithReference(encouragementApi)
    .WithReference(contactsApi)
    .WithBuildScript("build")
    .PublishAsStaticWebsite("/contacts", contactsApi);
#pragma warning restore ASPIREJAVASCRIPT001

if (builder.ExecutionContext.IsPublishMode)
{
    const string frontendOrigin = "https://love.maybeyourenotlost.com";
    encouragementApi.WithEnvironment("Frontend__Origin", frontendOrigin);
    contactsApi.WithEnvironment("Frontend__Origin", frontendOrigin);

    // PublishAsStaticWebsite always writes its YARP route/cluster under the fixed id "api",
    // so a second chained call for encouragementApi silently overwrote the contactsApi route
    // instead of adding to it. Register the second route by hand using the same env var
    // contract the helper uses, under a distinct id.
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