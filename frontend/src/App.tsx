import { useState } from "react";
import Home from "./pages/Home";
import EncourageSomeone from "./pages/EncourageSomeone";
import BeEncouraged from "./pages/BeEncouraged";

type Page = "home" | "encourage-someone" | "be-encouraged";

function App() {
  const [page, setPage] = useState<Page>("home");

  return (
    <div className="flex flex-col p-5 h-screen">
      {/* Top Section */}
      <div className="flex flex-col h-1/2 gap-4">
        <div className="flex flex-col gap-2 text-3xl font-bold">
          <span>Maybe</span>
          <span>You're</span>
          <span>Not</span>
          <span>Lost.</span>
        </div>
        <span className="text-sm w-1/2">
          You're right where you need to be.
        </span>
      </div>
      {/* Rest of Page */}
      <div className="flex flex-col flex-1">
        {page === "home" && (
          <Home
            onEncourageSomeone={() => setPage("encourage-someone")}
            onBeEncouraged={() => setPage("be-encouraged")}
          />
        )}
        {page === "encourage-someone" && <EncourageSomeone />}
        {page === "be-encouraged" && <BeEncouraged />}
      </div>
    </div>
  );
}

export default App;
