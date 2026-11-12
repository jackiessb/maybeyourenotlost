using Microsoft.EntityFrameworkCore.Migrations;

#nullable disable

namespace encouragement_api.Migrations
{
    /// <inheritdoc />
    public partial class AddEncouragementStatus : Migration
    {
        /// <inheritdoc />
        protected override void Up(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.AddColumn<int>(
                name: "Status",
                table: "Encouragements",
                type: "integer",
                nullable: false,
                defaultValue: -1);
        }

        /// <inheritdoc />
        protected override void Down(MigrationBuilder migrationBuilder)
        {
            migrationBuilder.DropColumn(
                name: "Status",
                table: "Encouragements");
        }
    }
}
