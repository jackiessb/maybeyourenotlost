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
    <div className="flex min-h-dvh flex-col">
      <header className="border-b">
        <div className="mx-auto flex max-w-5xl flex-wrap items-center gap-4 px-5 py-3">
          <h1 className="font-semibold">MYNL Dashboard</h1>
          <nav className="flex gap-1">
            <NavLink to="/contacts" className={navLinkClass}>
              Contacts
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
      <main className="mx-auto w-full max-w-5xl flex-1 p-5">
        <Outlet />
      </main>
    </div>
  );
}
