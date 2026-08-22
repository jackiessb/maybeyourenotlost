using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);

builder.AddServiceDefaults();

// Add services to the container.
// Learn more about configuring OpenAPI at https://aka.ms/aspnet/openapi
builder.Services.AddOpenApi();

// The mcr.microsoft.com/dotnet/aspnet base image ships no libgssapi_krb5.so.2, so Npgsql's
// GSS encryption negotiation throws on connect. GSS is Kerberos-only and unused here.
// Npgsql pools per process, so the ceiling that matters is (pool size x replica count).
// The server is a B1ms burstable with max_connections=50 and a few of those reserved for
// Azure's own monitoring, while Npgsql's default pool is 100 per replica -- two APIs scaling
// out would exhaust the server long before they exhaust a pool. Both APIs are capped to 3
// replicas (see scripts/apply-scale.sh), so 5 each bounds the pair at 30 connections. Every
// request here is a single-row insert or lookup that holds its connection for a few
// milliseconds, so 5 is far more throughput than a B1ms can commit anyway.
var connectionParams = ";Gss Encryption Mode=Disable;Maximum Pool Size=5";

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
builder.AddAzureNpgsqlDbContext<ContactsDbContext>("contacts",
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
