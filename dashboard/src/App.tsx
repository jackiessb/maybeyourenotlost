import { useEffect, useMemo, useState } from "react";
import { createHashRouter, Navigate, RouterProvider } from "react-router";
import { Toaster } from "./components/ui/toast";
import { Spinner } from "./components/ui/spinner";
import { Layout } from "./components/Layout";
import Encouragements from "./pages/Encouragements";
import EncouragementReview from "./pages/EncouragementReview";
import EncouragementTable from "./pages/EncouragementTable";
import { Home } from "./pages/Home";
import { fetchCurrentUser, redirectToLogin, type User } from "./lib/auth";

function createRouter(user: User) {
  // Hash routing so deep links work even if the static host has no SPA fallback.
  return createHashRouter([
    {
      path: "/",
      element: <Layout user={user} />,
      children: [
        { index: true, element: <Home user={user} /> },
        { path: "encouragements", element: <Encouragements /> },
        { path: "encouragements/review", element: <EncouragementReview /> },
        { path: "encouragements/browse", element: <EncouragementTable /> },
      ],
    },
    { path: "*", element: <Navigate to="/" replace /> },
  ]);
}

function App() {
  // null = still checking. Signed-out visitors are sent straight to Microsoft.
  const [user, setUser] = useState<User | null>(null);

  useEffect(() => {
    void fetchCurrentUser().then((current) => {
      if (current) {
        setUser(current);
      } else {
        redirectToLogin();
      }
    });
  }, []);

  const router = useMemo(() => (user ? createRouter(user) : null), [user]);

  return (
    <Toaster>
      {router ? (
        <RouterProvider router={router} />
      ) : (
        <div className="flex min-h-dvh items-center justify-center">
          <Spinner className="size-6 text-muted-foreground" />
        </div>
      )}
    </Toaster>
  );
}

export default App;
