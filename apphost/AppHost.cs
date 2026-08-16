var builder = DistributedApplication.CreateBuilder(args);

builder.AddNpmApp("frontend", "../frontend", "dev")
    .WithHttpEndpoint(env: "PORT")
    .WithExternalHttpEndpoints();

builder.AddNpmApp("event-handler", "../functions/event-handler", "watch");

builder.Build().Run();
