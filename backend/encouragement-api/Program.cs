using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);

builder.AddServiceDefaults();

// Add services to the container.
// Learn more about configuring OpenAPI at https://aka.ms/aspnet/openapi
builder.Services.AddOpenApi();

// The mcr.microsoft.com/dotnet/aspnet base image ships no libgssapi_krb5.so.2, so Npgsql's
// GSS encryption negotiation throws on connect. GSS is Kerberos-only and unused here.
var connectionParams = ";Gss Encryption Mode=Disable";

// Azure Postgres Flexible Server runs with require_secure_transport=on, and disabling GSS makes
// Npgsql skip SSL negotiation instead of falling through to it, so TLS has to be forced
// explicitly. The local dev container serves plaintext only, hence the guard.
if (!builder.Environment.IsDevelopment())
{
    connectionParams += ";Ssl Mode=Require";
}

// The server is Entra ID-only (passwordAuth disabled), so the provisioned connection string
// carries neither a username nor a password. AddAzureNpgsqlDbContext supplies both from the
// container's managed identity: the Postgres role name comes from the token's xms_mirid claim
// (= "mi-yudlalf6hmivo", the identity registered as the server's Entra admin) and a freshly
// acquired token is used as the password for every new physical connection.
builder.AddAzureNpgsqlDbContext<EncouragementDbContext>("encouragement",
    configureSettings: settings => settings.ConnectionString += connectionParams);

builder.Services.AddCors(options =>
{
    options.AddDefaultPolicy(policy =>
        policy.WithOrigins(builder.Configuration["Frontend:Origin"] ?? "http://localhost:5173")
            .AllowAnyHeader()
            .AllowAnyMethod());
});

var app = builder.Build();

using (var scope = app.Services.CreateScope())
{
    var db = scope.ServiceProvider.GetRequiredService<EncouragementDbContext>();
    db.Database.Migrate();
}

// Configure the HTTP request pipeline.
if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
}

app.UseHttpsRedirection();

app.UseCors();

app.MapGet("/health", () => Results.Ok(new { status = "healthy" }));

app.MapGet("/encouragements/{id:int}", async (int id, EncouragementDbContext db) =>
{
    var encouragement = await db.Encouragements.FindAsync(id);
    return encouragement is not null ? Results.Ok(encouragement) : Results.NotFound();
});

app.MapPost("/encouragements", async (CreateEncouragementRequest request, EncouragementDbContext db) =>
{
    if (string.IsNullOrWhiteSpace(request.Text))
    {
        return Results.ValidationProblem(new Dictionary<string, string[]>
        {
            ["text"] = ["Text is required."]
        });
    }

    var encouragement = new Encouragement { Text = request.Text.Trim() };
    db.Encouragements.Add(encouragement);
    await db.SaveChangesAsync();

    return Results.Created($"/encouragements/{encouragement.Id}", encouragement);
});

app.Run();

public record CreateEncouragementRequest(string Text);
