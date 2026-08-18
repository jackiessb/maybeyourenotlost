using Azure.Core;
using Azure.Identity;
using Microsoft.EntityFrameworkCore;
using Npgsql;

var builder = WebApplication.CreateBuilder(args);

builder.AddServiceDefaults();

// Add services to the container.
// Learn more about configuring OpenAPI at https://aka.ms/aspnet/openapi
builder.Services.AddOpenApi();

// The container image lacks libgssapi_krb5.so.2, so GSS encryption negotiation throws.
// Disabling it also skips Npgsql's SSL negotiation step instead of just falling through
// to it, so Ssl Mode must be forced explicitly or the connection goes out unencrypted,
// which Azure Postgres Flexible Server's pg_hba.conf rejects.
const string extraConnectionParams = ";Gss Encryption Mode=Disable;Ssl Mode=Require";

// This Postgres server has password auth disabled (Entra ID-only), so the provisioned
// connection string has no password. Aspire's Npgsql client integration doesn't acquire
// Entra tokens on its own, so a periodic password provider fetches one from the
// container's managed identity for every new physical connection.
var credential = new DefaultAzureCredential();
var dataSourceBuilder = new NpgsqlDataSourceBuilder(
    builder.Configuration.GetConnectionString("encouragement") + extraConnectionParams);
dataSourceBuilder.UsePeriodicPasswordProvider(async (_, ct) =>
{
    var token = await credential.GetTokenAsync(
        new TokenRequestContext(["https://ossrdbms-aad.database.windows.net/.default"]), ct);
    return token.Token;
}, TimeSpan.FromMinutes(55), TimeSpan.FromSeconds(10));
var npgsqlDataSource = dataSourceBuilder.Build();

builder.AddNpgsqlDbContext<EncouragementDbContext>("encouragement",
    configureSettings: settings => settings.ConnectionString += extraConnectionParams,
    configureDbContextOptions: options => options.UseNpgsql(npgsqlDataSource));

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
