public enum EncouragementStatus
{
    Waiting = -1,
    Rejected = 0,
    Approved = 1,
}

public class Encouragement
{
    public int Id { get; set; }
    public string Text { get; set; } = null!;
    public EncouragementStatus Status { get; set; } = EncouragementStatus.Waiting;
}
