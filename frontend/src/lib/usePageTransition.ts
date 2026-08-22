import { useEffect, useRef, useState } from "react";

/** How long the outgoing page takes to fade away, in ms. Keep in sync with
    the duration classes applied to the page wrapper in App. */
export const PAGE_FADE_OUT_MS = 220;

function prefersReducedMotion() {
  return (
    typeof window !== "undefined" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches
  );
}

/**
 * Defers a page switch until the current page has faded out, so the swap (and
 * the layout change that comes with it) happens while nothing is visible.
 *
 * Returns the page that should actually be rendered plus whether it is meant
 * to be showing right now.
 */
export function usePageTransition<T>(page: T) {
  const [rendered, setRendered] = useState(page);
  const [visible, setVisible] = useState(true);
  const timeout = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);

  useEffect(() => {
    if (page === rendered) return;

    if (prefersReducedMotion()) {
      setRendered(page);
      return;
    }

    setVisible(false);
    clearTimeout(timeout.current);
    timeout.current = setTimeout(() => {
      setRendered(page);
      setVisible(true);
    }, PAGE_FADE_OUT_MS);

    return () => clearTimeout(timeout.current);
  }, [page, rendered]);

  return { rendered, visible };
}
