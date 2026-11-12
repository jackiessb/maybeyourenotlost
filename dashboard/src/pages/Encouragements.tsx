import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { FieldError } from "@/components/ui/field";
import { Spinner } from "@/components/ui/spinner";
import { toast } from "@/components/ui/toast";
import { ListStatus } from "@/components/ListStatus";
import {
  deleteEncouragement,
  getEncouragements,
  getErrorMessage,
  getFieldErrors,
  setEncouragementStatus,
  updateEncouragement,
  EncouragementStatus,
  type Encouragement,
} from "@/lib/api";
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

function Encouragements() {
  const { items, isLoading, error, reload, replaceItem, removeItem } =
    useList(getEncouragements);
  const [editingId, setEditingId] = useState<number | null>(null);
  const [draft, setDraft] = useState("");
  const [fieldErrors, setFieldErrors] = useState<string[]>([]);
  const [busyId, setBusyId] = useState<number | null>(null);

  const startEdit = (encouragement: Encouragement) => {
    setEditingId(encouragement.id);
    setDraft(encouragement.text);
    setFieldErrors([]);
  };

  const cancelEdit = () => {
    setEditingId(null);
    setFieldErrors([]);
  };

  const handleSave = async (id: number) => {
    setBusyId(id);
    try {
      replaceItem(await updateEncouragement(id, draft));
      setEditingId(null);
      setFieldErrors([]);
      toast.add({ title: "Encouragement updated", type: "success" });
    } catch (e) {
      setFieldErrors(getFieldErrors(e, "text"));
      toast.add({
        title: "Couldn't update encouragement",
        description: getErrorMessage(e),
        type: "error",
      });
    } finally {
      setBusyId(null);
    }
  };

  const handleSetStatus = async (
    encouragement: Encouragement,
    status: EncouragementStatus,
  ) => {
    setBusyId(encouragement.id);
    try {
      replaceItem(await setEncouragementStatus(encouragement.id, status));
      toast.add({
        title: `Encouragement ${STATUS_LABELS[status].toLowerCase()}`,
        type: "success",
      });
    } catch (e) {
      toast.add({
        title: "Couldn't update status",
        description: getErrorMessage(e),
        type: "error",
      });
    } finally {
      setBusyId(null);
    }
  };

  const handleDelete = async (encouragement: Encouragement) => {
    if (!window.confirm(`Delete encouragement #${encouragement.id}?`)) {
      return;
    }

    setBusyId(encouragement.id);
    try {
      await deleteEncouragement(encouragement.id);
      removeItem(encouragement.id);
      toast.add({ title: "Encouragement deleted", type: "success" });
    } catch (e) {
      toast.add({
        title: "Couldn't delete encouragement",
        description: getErrorMessage(e),
        type: "error",
      });
    } finally {
      setBusyId(null);
    }
  };

  return (
    <section className="flex flex-col gap-4">
      <h2 className="text-xl font-semibold">Encouragements</h2>
      <ListStatus
        isLoading={isLoading}
        error={error}
        isEmpty={items.length === 0}
        emptyMessage="No encouragements yet."
        onRetry={reload}
      />
      {!isLoading && !error && items.length > 0 && (
        <ul className="flex flex-col divide-y rounded-2xl border">
          {items.map((encouragement) => {
            const isEditing = editingId === encouragement.id;
            const isBusy = busyId === encouragement.id;
            return (
              <li key={encouragement.id} className="flex flex-col gap-3 p-4">
                <div className="flex items-start gap-4">
                  <span className="w-12 shrink-0 text-sm text-muted-foreground">
                    #{encouragement.id}
                  </span>
                  <div className="min-w-0 flex-1">
                    {isEditing ? (
                      <div className="flex flex-col gap-1">
                        <Textarea
                          autoFocus
                          className="max-h-64 overflow-auto"
                          value={draft}
                          aria-label="Encouragement text"
                          aria-invalid={fieldErrors.length > 0}
                          onChange={(e) => setDraft(e.target.value)}
                          onKeyDown={(e) => {
                            if (e.key === "Escape") cancelEdit();
                          }}
                        />
                        <FieldError
                          errors={fieldErrors.map((message) => ({ message }))}
                        />
                      </div>
                    ) : (
                      <p className="text-sm break-words whitespace-pre-wrap">
                        {encouragement.text}
                      </p>
                    )}
                  </div>
                  <span
                    className={`shrink-0 rounded-full px-2 py-0.5 text-xs font-medium ${STATUS_STYLES[encouragement.status]}`}
                  >
                    {STATUS_LABELS[encouragement.status]}
                  </span>
                </div>
                <div className="flex justify-end gap-2">
                  {isEditing ? (
                    <>
                      <Button
                        size="sm"
                        onClick={() => handleSave(encouragement.id)}
                        disabled={isBusy}
                      >
                        {isBusy && <Spinner />}
                        Save
                      </Button>
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={cancelEdit}
                        disabled={isBusy}
                      >
                        Cancel
                      </Button>
                    </>
                  ) : (
                    <>
                      {encouragement.status !==
                        EncouragementStatus.Approved && (
                        <Button
                          size="sm"
                          onClick={() =>
                            handleSetStatus(
                              encouragement,
                              EncouragementStatus.Approved,
                            )
                          }
                          disabled={isBusy}
                        >
                          Approve
                        </Button>
                      )}
                      {encouragement.status !==
                        EncouragementStatus.Rejected && (
                        <Button
                          size="sm"
                          variant="outline"
                          onClick={() =>
                            handleSetStatus(
                              encouragement,
                              EncouragementStatus.Rejected,
                            )
                          }
                          disabled={isBusy}
                        >
                          Reject
                        </Button>
                      )}
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={() => startEdit(encouragement)}
                        disabled={isBusy}
                      >
                        Edit
                      </Button>
                      <Button
                        size="sm"
                        variant="destructive"
                        onClick={() => handleDelete(encouragement)}
                        disabled={isBusy}
                      >
                        {isBusy && <Spinner />}
                        Delete
                      </Button>
                    </>
                  )}
                </div>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}

export default Encouragements;
