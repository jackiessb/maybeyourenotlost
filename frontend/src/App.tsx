import { useState } from "react";
import Home from "./pages/Home";
import EncourageSomeone from "./pages/EncourageSomeone";
import BeEncouraged from "./pages/BeEncouraged";
import { Toaster } from "./components/ui/toast";
import { NavMenu } from "./components-mynl/NavMenu";
import { VideoBackground } from "./components-mynl/VideoBackground";

type Page = "home" | "encourage-someone" | "be-encouraged";

function App() {
  const [page, setPage] = useState<Page>("home");

  return (
    <>
      <VideoBackground />
      <div className="relative z-1 flex flex-col h-dvh">
        <NavMenu></NavMenu>
        <div className="flex flex-col flex-1 min-h-0 p-5">
          {/* Top Section */}
          <div className="flex flex-row justify-between h-1/2 gap-4">
            <div className="flex flex-col gap-2 text-3xl font-bold">
              <span>Maybe</span>
              <span>You're</span>
              <span>Not</span>
              <span>Lost.</span>
            </div>
          </div>
          {/* Rest of Page */}
          <div className="flex flex-col flex-1 min-h-0">
            {page === "home" && (
              <Home
                onEncourageSomeone={() => setPage("encourage-someone")}
                onBeEncouraged={() => setPage("be-encouraged")}
              />
            )}
            {page === "encourage-someone" && (
              <EncourageSomeone onBackToHome={() => setPage("home")} />
            )}
            {page === "be-encouraged" && (
              <BeEncouraged onBackToHome={() => setPage("home")} />
            )}
          </div>
          <Toaster />
        </div>
      </div>
    </>
  );
}

export default App;
