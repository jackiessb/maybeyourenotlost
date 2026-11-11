using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);

builder.AddServiceDefaults();

// Add services to the container.
// Learn more about configuring OpenAPI at https://aka.ms/aspnet/openapi
builder.Services.AddOpenApi();

var connectionParams = ";Gss Encryption Mode=Disable;Maximum Pool Size=5";

if (!builder.Environment.IsDevelopment())
{
    connectionParams += ";Ssl Mode=Require";
}

builder.AddAzureNpgsqlDbContext<ContactsDbContext>("contacts",
    configureSettings: settings => settings.ConnectionString += connectionParams);

builder.Services.AddCors(options =>
{
    options.AddDefaultPolicy(policy =>
        policy.WithOrigins(new[]
            {
                builder.Configuration["Frontend:Origin"] ?? "http://localhost:5173",
                builder.Configuration["Dashboard:Origin"]
            }.OfType<string>().ToArray())
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

// Admin routes are only reachable through the dashboard's reverse proxy, which sits behind
// Container Apps Easy Auth. The public frontend only forwards /contacts/**, never /admin/**.
var admin = app.MapGroup("/admin/contacts");

if (!app.Environment.IsDevelopment())
{
    // Easy Auth strips any client-supplied copy of this header and injects the signed-in user's.
    admin.AddEndpointFilter(async (context, next) =>
        string.IsNullOrEmpty(context.HttpContext.Request.Headers["X-MS-CLIENT-PRINCIPAL-ID"])
            ? Results.Unauthorized()
            : await next(context));
}

admin.MapGet("/", async (ContactsDbContext db) =>
    Results.Ok(await db.Contacts.OrderBy(c => c.Id).ToListAsync()));

admin.MapPut("/{id:int}", async (int id, UpdateContactRequest request, ContactsDbContext db) =>
{
    if (string.IsNullOrWhiteSpace(request.PhoneNumber))
    {
        return Results.ValidationProblem(new Dictionary<string, string[]>
        {
            ["phoneNumber"] = ["Phone number is required."]
        });
    }

    var contact = await db.Contacts.FindAsync(id);
    if (contact is null)
    {
        return Results.NotFound();
    }

    contact.PhoneNumber = request.PhoneNumber.Trim();
    await db.SaveChangesAsync();

    return Results.Ok(contact);
});

admin.MapDelete("/{id:int}", async (int id, ContactsDbContext db) =>
{
    var deleted = await db.Contacts.Where(c => c.Id == id).ExecuteDeleteAsync();
    return deleted > 0 ? Results.NoContent() : Results.NotFound();
});

app.Run();

public record CreateContactRequest(string PhoneNumber);

public record UpdateContactRequest(string PhoneNumber);
