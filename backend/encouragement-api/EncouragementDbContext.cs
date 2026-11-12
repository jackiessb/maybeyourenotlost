using Microsoft.EntityFrameworkCore;

public class EncouragementDbContext(DbContextOptions<EncouragementDbContext> options) : DbContext(options)
{
    public DbSet<Encouragement> Encouragements => Set<Encouragement>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        // Existing rows (and any insert that omits Status) become Waiting.
        modelBuilder.Entity<Encouragement>()
            .Property(e => e.Status)
            .HasDefaultValue(EncouragementStatus.Waiting)
            .HasSentinel(EncouragementStatus.Waiting);
    }
}
