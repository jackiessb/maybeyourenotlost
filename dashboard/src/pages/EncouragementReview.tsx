import { useEffect, useRef, useState } from "react";
import { BackToEncouragements } from "@/components/BackToEncouragements";
import { toast } from "@/components/ui/toast";
import { ListStatus } from "@/components/ListStatus";
import {
  getEncouragements,
  getErrorMessage,
  setEncouragementStatus,
  EncouragementStatus,
} from "@/lib/api";
import { useList } from "@/lib/useList";

type Direction = "left" | "right";

// How far (px) a card must be dragged before releasing it counts as a decision.
const SWIPE_THRESHOLD = 100;
// How long the fly-off animation runs before the card leaves the stack.
const EXIT_MS = 250;
// How many cards are rendered in the stack at once.
const VISIBLE_CARDS = 3;
// How long the progress bar stays tinted after a decision.
const FLASH_MS = 500;

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

function EncouragementReview() {
  const { items, isLoading, error, reload, replaceItem } =
    useList(getEncouragements);
  const [dragX, setDragX] = useState(0);
  const [isDragging, setIsDragging] = useState(false);
  const [exiting, setExiting] = useState<Direction | null>(null);
  const dragStartX = useRef<number | null>(null);
  const [flash, setFlash] = useState<Direction | null>(null);
  const flashTimer = useRef<ReturnType<typeof setTimeout>>(undefined);

  const flashProgress = (direction: Direction) => {
    clearTimeout(flashTimer.current);
    setFlash(direction);
    flashTimer.current = setTimeout(() => setFlash(null), FLASH_MS);
  };

  useEffect(() => () => clearTimeout(flashTimer.current), []);

  const deck = items.filter((e) => e.status === EncouragementStatus.Waiting);
  const top = deck[0];

  const total = items.length;
  const remaining = deck.length;
  const reviewed = total - remaining;
  const percent = total === 0 ? 0 : Math.round((reviewed / total) * 100);

  const decide = async (direction: Direction) => {
    if (!top || exiting) return;

    const status =
      direction === "right"
        ? EncouragementStatus.Approved
        : EncouragementStatus.Rejected;

    setIsDragging(false);
    dragStartX.current = null;
    setExiting(direction);

    try {
      const [updated] = await Promise.all([
        setEncouragementStatus(top.id, status),
        wait(EXIT_MS),
      ]);
      replaceItem(updated);
      flashProgress(direction);
    } catch (e) {
      toast.add({
        title: "Couldn't update status",
        description: getErrorMessage(e),
        type: "error",
      });
    } finally {
      // The next card (or the failed one, snapping back) starts at rest.
      setExiting(null);
      setDragX(0);
    }
  };

  // Arrow keys for desktop: left rejects, right approves.
  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
      const target = event.target as HTMLElement | null;
      if (
        target &&
        (target.isContentEditable ||
          ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName))
      ) {
        return;
      }
      event.preventDefault();
      void decide(event.key === "ArrowLeft" ? "left" : "right");
    };

    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  });

  const handlePointerDown = (event: React.PointerEvent<HTMLElement>) => {
    if (exiting) return;
    dragStartX.current = event.clientX;
    setIsDragging(true);
    event.currentTarget.setPointerCapture(event.pointerId);
  };

  const handlePointerMove = (event: React.PointerEvent<HTMLElement>) => {
    if (dragStartX.current === null) return;
    setDragX(event.clientX - dragStartX.current);
  };

  const handlePointerEnd = () => {
    if (dragStartX.current === null) return;
    dragStartX.current = null;
    setIsDragging(false);

    if (dragX > SWIPE_THRESHOLD) {
      void decide("right");
    } else if (dragX < -SWIPE_THRESHOLD) {
      void decide("left");
    } else {
      setDragX(0);
    }
  };

  const topOffset =
    exiting === "right"
      ? window.innerWidth
      : exiting === "left"
        ? -window.innerWidth
        : dragX;
  const intent = Math.min(Math.abs(dragX) / SWIPE_THRESHOLD, 1);

  return (
    <>
      <BackToEncouragements />
      <div className="flex flex-row justify-between items-center gap-3">
        <div className="flex justify-between text-sm text-muted-foreground pt-1.5">
          <span>
            {remaining === 0 ? "All reviewed" : `${remaining} left to review`}
          </span>
        </div>
        <p className="text-[14px] text-muted-foreground left-auto italic">
          <span>Swipe left to reject, swipe right to approve</span>
        </p>
      </div>
      {!isLoading && !error && total > 0 && (
        <div className="flex flex-col gap-1.5">
          <div
            role="progressbar"
            aria-label="Encouragements reviewed"
            aria-valuemin={0}
            aria-valuemax={total}
            aria-valuenow={reviewed}
            className="h-2 w-full overflow-hidden rounded-full bg-muted"
          >
            <div
              className={`h-full rounded-full transition-all duration-300 ${
                flash === "right"
                  ? "bg-green-600"
                  : flash === "left"
                    ? "bg-destructive"
                    : "bg-primary"
              }`}
              style={{ width: `${percent}%` }}
            />
          </div>
        </div>
      )}
      <ListStatus
        isLoading={isLoading}
        error={error}
        isEmpty={items.length === 0}
        emptyMessage="No encouragements yet."
        onRetry={reload}
      />
      {!isLoading && !error && total > 0 && remaining === 0 && (
        <p className="py-16 text-center text-lg text-muted-foreground">
          No more encouragements left to review.
        </p>
      )}
      {!isLoading && !error && remaining > 0 && (
        <>
          <div className="relative mx-auto mb-6 min-h-80 w-full max-w-xl flex-1">
            {deck.slice(0, VISIBLE_CARDS).map((encouragement, index) => {
              const isTop = index === 0;
              const style: React.CSSProperties = isTop
                ? {
                    transform: `translateX(${topOffset}px) rotate(${topOffset / 20}deg)`,
                    transition: isDragging
                      ? "none"
                      : `transform ${EXIT_MS}ms ease-out`,
                    zIndex: VISIBLE_CARDS,
                  }
                : {
                    transform: `translateY(${index * 12}px) scale(${1 - index * 0.05})`,
                    transition: `transform ${EXIT_MS}ms ease-out`,
                    zIndex: VISIBLE_CARDS - index,
                  };

              return (
                <article
                  key={encouragement.id}
                  className={`absolute inset-0 flex flex-col overflow-y-auto rounded-2xl border bg-card p-6 shadow-sm select-none sm:p-8 ${
                    isTop
                      ? "cursor-grab touch-pan-y active:cursor-grabbing"
                      : "pointer-events-none"
                  }`}
                  style={style}
                  {...(isTop && {
                    onPointerDown: handlePointerDown,
                    onPointerMove: handlePointerMove,
                    onPointerUp: handlePointerEnd,
                    onPointerCancel: handlePointerEnd,
                  })}
                >
                  <p className="my-auto text-center text-xl leading-relaxed wrap-break-word whitespace-pre-wrap">
                    {encouragement.text}
                  </p>
                  {isTop && (
                    <>
                      <span
                        className="pointer-events-none absolute top-4 right-4 rounded-lg border-2 border-green-600 px-2 py-1 text-sm font-bold tracking-wide text-green-600 uppercase"
                        style={{ opacity: dragX > 0 ? intent : 0 }}
                      >
                        Approve
                      </span>
                      <span
                        className="pointer-events-none absolute top-4 left-4 rounded-lg border-2 border-destructive px-2 py-1 text-sm font-bold tracking-wide text-destructive uppercase"
                        style={{ opacity: dragX < 0 ? intent : 0 }}
                      >
                        Reject
                      </span>
                    </>
                  )}
                </article>
              );
            })}
          </div>
        </>
      )}
    </>
  );
}

export default EncouragementReview;
