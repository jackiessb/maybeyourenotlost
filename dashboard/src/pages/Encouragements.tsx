import { Link } from "react-router";
import { getEncouragements, EncouragementStatus } from "@/lib/api";
import { useList } from "@/lib/useList";

interface HubLinkProps {
  to: string;
  title: string;
  description: string;
  detail?: string;
}

function HubLink({ to, title, description }: HubLinkProps) {
  return (
    <Link
      to={to}
      className="flex flex-col gap-1 rounded-2xl border bg-card p-6 text-card-foreground shadow-sm transition-colors hover:bg-muted focus-visible:ring-3 focus-visible:ring-ring/30 focus-visible:outline-none"
    >
      <span className="text-lg font-semibold">{title}</span>
      <span className="text-sm text-muted-foreground">{description}</span>
    </Link>
  );
}

function Encouragements() {
  return (
    <>
      <h2 className="text-xl font-semibold">Encouragements</h2>
      <div className="grid gap-4 sm:grid-cols-2">
        <HubLink
          to="/encouragements/review"
          title="Review"
          description="Swipe or use the arrow keys to approve or reject new encouragements."
        />
        <HubLink
          to="/encouragements/browse"
          title="Browse"
          description="Search and scroll through encouragements."
        />
      </div>
    </>
  );
}

export default Encouragements;
