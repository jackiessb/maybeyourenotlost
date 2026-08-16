var builder = DistributedApplication.CreateBuilder(args);

var encouragementApi = builder.AddProject<Projects.encouragement_api>("encouragement-api");
var contactsApi = builder.AddProject<Projects.contacts_api>("contacts-api");

builder.AddNpmApp("frontend", "../frontend", "dev")
    .WithHttpEndpoint(env: "PORT")
    .WithExternalHttpEndpoints()
    .WithReference(encouragementApi)
    .WithReference(contactsApi);

builder.Build().Run();