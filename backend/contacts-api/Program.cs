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
    builder.Configuration.GetConnectionString("contacts") + extraConnectionParams);
dataSourceBuilder.UsePeriodicPasswordProvider(async (_, ct) =>
{
    var token = await credential.GetTokenAsync(
        new TokenRequestContext(["https://ossrdbms-aad.database.windows.net/.default"]), ct);
    return token.Token;
}, TimeSpan.FromMinutes(55), TimeSpan.FromSeconds(10));
var npgsqlDataSource = dataSourceBuilder.Build();

builder.AddNpgsqlDbContext<ContactsDbContext>("contacts",
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
    var db = scope.ServiceProvider.GetRequiredService<ContactsDbContext>();
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

app.MapGet("/contacts/{id:int}", async (int id, ContactsDbContext db) =>
{
    var contact = await db.Contacts.FindAsync(id);
    return contact is not null ? Results.Ok(contact) : Results.NotFound();
});

app.MapPost("/contacts", async (CreateContactRequest request, ContactsDbContext db) =>
{
    if (string.IsNullOrWhiteSpace(request.PhoneNumber))
    {
        return Results.ValidationProblem(new Dictionary<string, string[]>
        {
            ["phoneNumber"] = ["Phone number is required."]
        });
    }

    var contact = new Contact { PhoneNumber = request.PhoneNumber.Trim() };
    db.Contacts.Add(contact);
    await db.SaveChangesAsync();

    return Results.Created($"/contacts/{contact.Id}", contact);
});

app.Run();

public record CreateContactRequest(string PhoneNumber);
