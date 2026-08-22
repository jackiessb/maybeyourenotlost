import { useState } from "react";
import Home from "./pages/Home";
import EncourageSomeone from "./pages/EncourageSomeone";
import BeEncouraged from "./pages/BeEncouraged";
import About from "./pages/About";
import { Toaster } from "./components/ui/toast";
import { NavMenu } from "./components-mynl/NavMenu";
import { VideoBackground } from "./components-mynl/VideoBackground";
import { usePageTransition } from "./lib/usePageTransition";

type Page = "home" | "encourage-someone" | "be-encouraged" | "about";

function App() {
  const [page, setPage] = useState<Page>("home");
  const { rendered, visible } = usePageTransition(page);

  return (
    <>
      <VideoBackground />
      <div className="relative z-1 flex flex-col h-dvh">
        <NavMenu
          onBackToHome={() => setPage("home")}
          onToAbout={() => setPage("about")}
        ></NavMenu>
        <div className="flex flex-col flex-1 min-h-0 p-5">
          {/* Top Section */}
          <div
            className={`flex flex-row justify-between gap-4 ${
              rendered === "about" ? "h-auto pb-4" : "h-1/2"
            }`}
          >
            <div className="flex flex-col gap-2 text-3xl font-bold">
              <span>Maybe</span>
              <span>You're</span>
              <span>Not</span>
              <span>Lost.</span>
            </div>
          </div>
          {/* Rest of Page */}
          <div
            key={rendered}
            className={`flex flex-col flex-1 min-h-0 motion-reduce:animate-none motion-reduce:transition-none ${
              visible
                ? "animate-in fade-in slide-in-from-bottom-2 duration-500 ease-out"
                : "opacity-0 translate-y-2 transition-all duration-200 ease-in"
            }`}
          >
            {rendered === "home" && (
              <Home
                onEncourageSomeone={() => setPage("encourage-someone")}
                onBeEncouraged={() => setPage("be-encouraged")}
              />
            )}
            {rendered === "encourage-someone" && (
              <EncourageSomeone onBackToHome={() => setPage("home")} />
            )}
            {rendered === "be-encouraged" && (
              <BeEncouraged onBackToHome={() => setPage("home")} />
            )}
            {rendered === "about" && (
              <About onBackToHome={() => setPage("home")} />
            )}
          </div>
          <Toaster />
        </div>
      </div>
    </>
  );
}

export default App;
