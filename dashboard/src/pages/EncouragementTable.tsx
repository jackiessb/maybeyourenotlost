import { useState } from "react";
import { BackToEncouragements } from "@/components/BackToEncouragements";
import { Input } from "@/components/ui/input";
import { ListStatus } from "@/components/ListStatus";
import { getEncouragements, EncouragementStatus } from "@/lib/api";
import { useList } from "@/lib/useList";

const STATUS_LABELS: Record<EncouragementStatus, string> = {
  [EncouragementStatus.Waiting]: "Waiting",
  [EncouragementStatus.Rejected]: "Rejected",
  [EncouragementStatus.Approved]: "Approved",
};

const STATUS_STYLES: Record<EncouragementStatus, string> = {
  [EncouragementStatus.Waiting]: "bg-muted text-muted-foreground",
  [EncouragementStatus.Rejected]: "bg-destructive/10 text-destructive",
  [EncouragementStatus.Approved]: "bg-green-600/10 text-green-700",
};

function EncouragementTable() {
  const { items, isLoading, error, reload } = useList(getEncouragements);
  const [query, setQuery] = useState("");

  const needle = query.trim().toLowerCase();
  const matches = needle
    ? items.filter((e) => e.text.toLowerCase().includes(needle))
    : items;

  return (
    <>
      <BackToEncouragements />
      <Input
        type="search"
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        placeholder="Search encouragements…"
        aria-label="Search encouragements"
      />
      <ListStatus
        isLoading={isLoading}
        error={error}
        isEmpty={items.length === 0}
        emptyMessage="No encouragements yet."
        onRetry={reload}
      />
      {!isLoading && !error && items.length > 0 && (
        <>
          {matches.length === 0 ? (
            <p className="py-16 text-center text-muted-foreground">
              No encouragements match this search.
            </p>
          ) : (
            <div className="min-h-0 overflow-auto rounded-2xl border">
              <table className="w-full text-left text-sm">
                <thead className="sticky top-0 bg-muted text-muted-foreground">
                  <tr>
                    <th scope="col" className="px-4 py-2 font-medium">
                      Encouragement
                    </th>
                    <th scope="col" className="px-4 py-2 font-medium">
                      Status
                    </th>
                  </tr>
                </thead>
                <tbody className="divide-y">
                  {matches.map((encouragement) => (
                    <tr key={encouragement.id}>
                      <td className="px-4 py-3 wrap-break-word whitespace-pre-wrap">
                        {encouragement.text}
                      </td>
                      <td className="px-4 py-3 align-top">
                        <span
                          className={`inline-block rounded-full px-2 py-0.5 text-xs font-medium ${STATUS_STYLES[encouragement.status]}`}
                        >
                          {STATUS_LABELS[encouragement.status]}
                        </span>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}
    </>
  );
}

export default EncouragementTable;
