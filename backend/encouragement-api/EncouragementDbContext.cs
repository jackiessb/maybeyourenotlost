using Microsoft.EntityFrameworkCore;

public class EncouragementDbContext(DbContextOptions<EncouragementDbContext> options) : DbContext(options)
{
    public DbSet<Encouragement> Encouragements => Set<Encouragement>();
}
