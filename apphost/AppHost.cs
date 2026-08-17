var builder = DistributedApplication.CreateBuilder(args);

var postgres = builder.AddAzurePostgresFlexibleServer("postgres")
    .RunAsContainer();

var encouragementDb = postgres.AddDatabase("encouragement");
var contactsDb = postgres.AddDatabase("contacts");

var encouragementApi = builder.AddProject<Projects.encouragement_api>("encouragement-api")
    .WithReference(encouragementDb);
var contactsApi = builder.AddProject<Projects.contacts_api>("contacts-api")
    .WithReference(contactsDb);

builder.AddJavaScriptApp("frontend", "../frontend", "dev")
    .WithHttpEndpoint(env: "PORT")
    .WithExternalHttpEndpoints()
    .WithReference(encouragementApi)
    .WithReference(contactsApi);

builder.Build().Run();