using Microsoft.EntityFrameworkCore;

public class ContactsDbContext(DbContextOptions<ContactsDbContext> options) : DbContext(options)
{
    public DbSet<Contact> Contacts => Set<Contact>();
}
