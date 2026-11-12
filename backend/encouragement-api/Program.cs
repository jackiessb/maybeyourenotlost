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

builder.AddAzureNpgsqlDbContext<EncouragementDbContext>("encouragement",
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
    // Only approved encouragements are visible to the public.
    var encouragement = await db.Encouragements
        .FirstOrDefaultAsync(e => e.Id == id && e.Status == EncouragementStatus.Approved);
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

// Admin routes are only reachable through the dashboard's reverse proxy, which sits behind
// Container Apps Easy Auth. The public frontend only forwards /encouragements/**, never /admin/**.
var admin = app.MapGroup("/admin/encouragements");

if (!app.Environment.IsDevelopment())
{
    // Easy Auth strips any client-supplied copy of this header and injects the signed-in user's.
    admin.AddEndpointFilter(async (context, next) =>
        string.IsNullOrEmpty(context.HttpContext.Request.Headers["X-MS-CLIENT-PRINCIPAL-ID"])
            ? Results.Unauthorized()
            : await next(context));
}

admin.MapGet("/", async (EncouragementDbContext db) =>
    Results.Ok(await db.Encouragements.OrderBy(e => e.Id).ToListAsync()));

admin.MapPut("/{id:int}", async (int id, UpdateEncouragementRequest request, EncouragementDbContext db) =>
{
    if (string.IsNullOrWhiteSpace(request.Text))
    {
        return Results.ValidationProblem(new Dictionary<string, string[]>
        {
            ["text"] = ["Text is required."]
        });
    }

    var encouragement = await db.Encouragements.FindAsync(id);
    if (encouragement is null)
    {
        return Results.NotFound();
    }

    encouragement.Text = request.Text.Trim();
    await db.SaveChangesAsync();

    return Results.Ok(encouragement);
});

admin.MapPut("/{id:int}/status", async (int id, UpdateEncouragementStatusRequest request, EncouragementDbContext db) =>
{
    if (!Enum.IsDefined(request.Status))
    {
        return Results.ValidationProblem(new Dictionary<string, string[]>
        {
            ["status"] = ["Status must be -1 (waiting), 0 (rejected) or 1 (approved)."]
        });
    }

    var encouragement = await db.Encouragements.FindAsync(id);
    if (encouragement is null)
    {
        return Results.NotFound();
    }

    encouragement.Status = request.Status;
    await db.SaveChangesAsync();

    return Results.Ok(encouragement);
});

admin.MapDelete("/{id:int}", async (int id, EncouragementDbContext db) =>
{
    var deleted = await db.Encouragements.Where(e => e.Id == id).ExecuteDeleteAsync();
    return deleted > 0 ? Results.NoContent() : Results.NotFound();
});

app.Run();

public record CreateEncouragementRequest(string Text);

public record UpdateEncouragementRequest(string Text);

public record UpdateEncouragementStatusRequest(EncouragementStatus Status);
