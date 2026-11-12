import { Link } from "react-router";

export function BackToEncouragements() {
  return (
    <Link
      to="/encouragements"
      className="self-start text-sm text-muted-foreground underline-offset-4 hover:text-foreground hover:underline"
    >
      ← Encouragements
    </Link>
  );
}
