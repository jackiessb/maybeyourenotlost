import { Button } from "@/components/ui/button";
import { Spinner } from "@/components/ui/spinner";

interface ListStatusProps {
  isLoading: boolean;
  error: string | null;
  isEmpty: boolean;
  emptyMessage: string;
  onRetry: () => void;
}

/** Renders the loading, error, or empty state for a list, or null if none apply. */
export function ListStatus({
  isLoading,
  error,
  isEmpty,
  emptyMessage,
  onRetry,
}: ListStatusProps) {
  if (isLoading) {
    return (
      <div className="flex items-center justify-center gap-2 py-16 text-muted-foreground">
        <Spinner />
        Loading…
      </div>
    );
  }

  if (error) {
    return (
      <div className="flex flex-col items-center gap-3 py-16 text-center">
        <p className="text-destructive">{error}</p>
        <Button variant="outline" onClick={onRetry}>
          Retry
        </Button>
      </div>
    );
  }

  if (isEmpty) {
    return (
      <p className="py-16 text-center text-muted-foreground">{emptyMessage}</p>
    );
  }

  return null;
}
