import { useEffect, useState } from "react";
import { getErrorMessage } from "./api";

/** Loads a list from the API and exposes helpers to patch it after edits. */
export function useList<T extends { id: number }>(load: () => Promise<T[]>) {
  const [items, setItems] = useState<T[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  // Bumping this re-runs the fetch effect (used by "Retry").
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    let ignore = false;
    load()
      .then(
        (result) => !ignore && setItems(result),
        (e: unknown) => !ignore && setError(getErrorMessage(e)),
      )
      .finally(() => !ignore && setIsLoading(false));
    return () => {
      ignore = true;
    };
  }, [load, attempt]);

  const reload = () => {
    setIsLoading(true);
    setError(null);
    setAttempt((n) => n + 1);
  };

  const replaceItem = (updated: T) =>
    setItems((current) =>
      current.map((item) => (item.id === updated.id ? updated : item)),
    );

  const removeItem = (id: number) =>
    setItems((current) => current.filter((item) => item.id !== id));

  return { items, isLoading, error, reload, replaceItem, removeItem };
}
