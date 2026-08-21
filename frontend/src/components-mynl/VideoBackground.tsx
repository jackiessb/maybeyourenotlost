import { useEffect, useRef, useState } from "react";
import { cn } from "@/lib/utils";

const POSTER_SRC = "/bg-loop-poster.jpg";

// Reduced motion or a metered connection means we never request the ~2MB loop —
// the poster is already painted and simply stays as the background.
function prefersStillBackground() {
  if (typeof window === "undefined") return false;

  const reducedMotion = window.matchMedia(
    "(prefers-reduced-motion: reduce)",
  ).matches;
  const saveData =
    (navigator as Navigator & { connection?: { saveData?: boolean } })
      .connection?.saveData === true;

  return reducedMotion || saveData;
}

export function VideoBackground() {
  const [isStill] = useState(prefersStillBackground);
  const [isPlaying, setIsPlaying] = useState(false);
  const videoRef = useRef<HTMLVideoElement>(null);

  useEffect(() => {
    const video = videoRef.current;
    if (isStill || !video) return;

    // Safari can fire canplay before React attaches the handler.
    if (video.readyState >= video.HAVE_FUTURE_DATA) setIsPlaying(true);

    // autoPlay is enough almost everywhere, but some browsers reject the first
    // attempt; muted + playsInline keeps this allowed under iOS autoplay policy.
    void video.play().catch(() => {});
  }, [isStill]);

  return (
    <div
      aria-hidden
      className="pointer-events-none fixed inset-0 -z-1 overflow-hidden bg-background"
    >
      <img
        src={POSTER_SRC}
        alt=""
        className="absolute inset-0 size-full object-cover"
      />
      {!isStill && (
        <video
          ref={videoRef}
          muted
          loop
          autoPlay
          playsInline
          preload="auto"
          tabIndex={-1}
          disablePictureInPicture
          poster={POSTER_SRC}
          onCanPlay={() => setIsPlaying(true)}
          className={cn(
            "absolute inset-0 size-full object-cover transition-opacity duration-700",
            isPlaying ? "opacity-100" : "opacity-0",
          )}
        >
          <source src="/bg-loop-v1.webm" type="video/webm" />
          <source src="/bg-loop-v1.mp4" type="video/mp4" />
        </video>
      )}
      {/* Scrim: flat dim plus a vertical gradient so the headline up top and the
          buttons further down both land on darker pixels. */}
      <div className="absolute inset-0 bg-black/40" />
      <div className="absolute inset-0 bg-gradient-to-b from-black/40 via-transparent to-black/50" />
    </div>
  );
}
