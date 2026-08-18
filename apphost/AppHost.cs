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
    .PublishAsStaticWebsite("/contacts", contactsApi)
    .PublishAsStaticWebsite("/encouragements", encouragementApi);
#pragma warning restore ASPIREJAVASCRIPT001

encouragementApi.WithEnvironment("Frontend__Origin", frontend.GetEndpoint("http"));
contactsApi.WithEnvironment("Frontend__Origin", frontend.GetEndpoint("http"));

builder.Build().Run();