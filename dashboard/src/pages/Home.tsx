import { Link } from "react-router";
import { buttonVariants } from "@/components/ui/button";
import { getEncouragements, EncouragementStatus } from "@/lib/api";
import { useList } from "@/lib/useList";
import { cn } from "@/lib/utils";
import type { User } from "@/lib/auth";

function getGreeting(date = new Date()) {
  const hour = date.getHours();
  if (hour < 12) return "Good morning";
  if (hour < 18) return "Good afternoon";
  return "Good evening";
}

export function Home({ user }: { user: User }) {
  const { items } = useList(getEncouragements);
  const waitingCount = items.filter(
    (e) => e.status === EncouragementStatus.Waiting,
  ).length;

  return (
    <>
      <h2 className="text-xl font-semibold">
        {getGreeting()}, {user.name.split(" ")[0]}
      </h2>
      {waitingCount > 0 && (
        <div className="flex flex-wrap items-center justify-between gap-3 rounded-2xl border bg-card p-4 text-card-foreground">
          <p className="text-sm">
            <span className="font-semibold">{waitingCount}</span> new{" "}
            {waitingCount === 1 ? "encouragement is" : "encouragements are"}{" "}
            waiting for review.
          </p>
          <Link to="/encouragements/review" className={cn(buttonVariants())}>
            Review now
          </Link>
        </div>
      )}
    </>
  );
}
