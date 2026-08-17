using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);

// Add services to the container.
// Learn more about configuring OpenAPI at https://aka.ms/aspnet/openapi
builder.Services.AddOpenApi();

builder.AddNpgsqlDbContext<EncouragementDbContext>("encouragement");

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
