import { NavLink, Outlet } from "react-router";
import { LOGOUT_URL, type User } from "@/lib/auth";
import { cn } from "@/lib/utils";

interface LayoutProps {
  user: User;
}

const navLinkClass = ({ isActive }: { isActive: boolean }) =>
  cn(
    "rounded-2xl px-3 py-1.5 text-sm font-medium transition-colors hover:bg-muted",
    isActive ? "bg-muted text-foreground" : "text-muted-foreground",
  );

export function Layout({ user }: LayoutProps) {
  return (
    <div className="flex h-dvh flex-col overflow-hidden">
      <header className="border-b">
        <div className="mx-auto flex max-w-5xl flex-wrap items-center gap-4 px-5 py-3">
          <h1 className="font-semibold">Maybe You're Not Lost</h1>
          <nav className="flex gap-1">
            <NavLink to="/" end className={navLinkClass}>
              Home
            </NavLink>
            <NavLink to="/encouragements" className={navLinkClass}>
              Encouragements
            </NavLink>
          </nav>
          <div className="ml-auto flex items-center gap-4 text-sm">
            <span className="text-muted-foreground">{user.name}</span>
            <a
              href={LOGOUT_URL}
              className="font-medium underline-offset-4 hover:underline"
            >
              Sign out
            </a>
          </div>
        </div>
      </header>
      <main className="min-h-0 flex-1 overflow-x-hidden overflow-y-auto">
        <div className="mx-auto h-full w-full max-w-5xl p-5">
          <section className="flex h-full flex-col gap-4">
            <Outlet />
          </section>
        </div>
      </main>
    </div>
  );
}
