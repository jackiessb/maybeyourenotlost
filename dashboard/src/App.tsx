import { useEffect, useMemo, useState } from "react";
import { createHashRouter, Navigate, RouterProvider } from "react-router";
import { Toaster } from "./components/ui/toast";
import { Spinner } from "./components/ui/spinner";
import { Layout } from "./components/Layout";
import Contacts from "./pages/Contacts";
import Encouragements from "./pages/Encouragements";
import Login from "./pages/Login";
import { fetchCurrentUser, type User } from "./lib/auth";

function createRouter(user: User | null) {
  // Hash routing so deep links work even if the static host has no SPA fallback.
  return createHashRouter([
    {
      path: "/login",
      element: user ? <Navigate to="/contacts" replace /> : <Login />,
    },
    {
      path: "/",
      element: user ? <Layout user={user} /> : <Navigate to="/login" replace />,
      children: [
        { index: true, element: <Navigate to="/contacts" replace /> },
        { path: "contacts", element: <Contacts /> },
        { path: "encouragements", element: <Encouragements /> },
      ],
    },
    { path: "*", element: <Navigate to="/" replace /> },
  ]);
}

function App() {
  // undefined = still checking, null = signed out.
  const [user, setUser] = useState<User | null | undefined>(undefined);

  useEffect(() => {
    void fetchCurrentUser().then(setUser);
  }, []);

  const router = useMemo(
    () => (user === undefined ? null : createRouter(user)),
    [user],
  );

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
