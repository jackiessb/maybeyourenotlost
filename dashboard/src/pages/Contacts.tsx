import { useState } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { FieldError } from "@/components/ui/field";
import { Spinner } from "@/components/ui/spinner";
import { toast } from "@/components/ui/toast";
import { ListStatus } from "@/components/ListStatus";
import {
  deleteContact,
  getContacts,
  getErrorMessage,
  getFieldErrors,
  updateContact,
  type Contact,
} from "@/lib/api";
import { formatPhoneNumber, toE164 } from "@/lib/phone";
import { useList } from "@/lib/useList";

function Contacts() {
  const { items, isLoading, error, reload, replaceItem, removeItem } =
    useList(getContacts);
  const [editingId, setEditingId] = useState<number | null>(null);
  const [draft, setDraft] = useState("");
  const [fieldErrors, setFieldErrors] = useState<string[]>([]);
  const [busyId, setBusyId] = useState<number | null>(null);

  const startEdit = (contact: Contact) => {
    setEditingId(contact.id);
    setDraft(formatPhoneNumber(contact.phoneNumber));
    setFieldErrors([]);
  };

  const cancelEdit = () => {
    setEditingId(null);
    setFieldErrors([]);
  };

  const handleSave = async (id: number) => {
    const phoneNumber = toE164(draft);
    if (!phoneNumber) {
      setFieldErrors(["Enter a valid 10-digit US phone number."]);
      return;
    }

    setBusyId(id);
    try {
      replaceItem(await updateContact(id, phoneNumber));
      setEditingId(null);
      setFieldErrors([]);
      toast.add({ title: "Contact updated", type: "success" });
    } catch (e) {
      setFieldErrors(getFieldErrors(e, "phoneNumber"));
      toast.add({
        title: "Couldn't update contact",
        description: getErrorMessage(e),
        type: "error",
      });
    } finally {
      setBusyId(null);
    }
  };

  const handleDelete = async (contact: Contact) => {
    if (
      !window.confirm(
        `Delete contact ${formatPhoneNumber(contact.phoneNumber)}?`,
      )
    ) {
      return;
    }

    setBusyId(contact.id);
    try {
      await deleteContact(contact.id);
      removeItem(contact.id);
      toast.add({ title: "Contact deleted", type: "success" });
    } catch (e) {
      toast.add({
        title: "Couldn't delete contact",
        description: getErrorMessage(e),
        type: "error",
      });
    } finally {
      setBusyId(null);
    }
  };

  return (
    <section className="flex flex-col gap-4">
      <h2 className="text-xl font-semibold">Contacts</h2>
      <ListStatus
        isLoading={isLoading}
        error={error}
        isEmpty={items.length === 0}
        emptyMessage="No contacts yet."
        onRetry={reload}
      />
      {!isLoading && !error && items.length > 0 && (
        <div className="overflow-x-auto rounded-2xl border">
          <table className="w-full text-sm">
            <thead className="bg-muted/50 text-left text-muted-foreground">
              <tr>
                <th className="w-20 px-4 py-2 font-medium">ID</th>
                <th className="px-4 py-2 font-medium">Phone number</th>
                <th className="w-48 px-4 py-2 text-right font-medium">
                  Actions
                </th>
              </tr>
            </thead>
            <tbody>
              {items.map((contact) => {
                const isEditing = editingId === contact.id;
                const isBusy = busyId === contact.id;
                return (
                  <tr key={contact.id} className="border-t align-top">
                    <td className="px-4 py-3 text-muted-foreground">
                      {contact.id}
                    </td>
                    <td className="px-4 py-3">
                      {isEditing ? (
                        <div className="flex max-w-xs flex-col gap-1">
                          <Input
                            type="tel"
                            autoFocus
                            value={draft}
                            aria-label="Phone number"
                            aria-invalid={fieldErrors.length > 0}
                            onChange={(e) =>
                              setDraft(formatPhoneNumber(e.target.value))
                            }
                            onKeyDown={(e) => {
                              if (e.key === "Enter")
                                void handleSave(contact.id);
                              if (e.key === "Escape") cancelEdit();
                            }}
                          />
                          <FieldError
                            errors={fieldErrors.map((message) => ({ message }))}
                          />
                        </div>
                      ) : (
                        formatPhoneNumber(contact.phoneNumber)
                      )}
                    </td>
                    <td className="px-4 py-3">
                      <div className="flex justify-end gap-2">
                        {isEditing ? (
                          <>
                            <Button
                              size="sm"
                              onClick={() => handleSave(contact.id)}
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
                            <Button
                              size="sm"
                              variant="outline"
                              onClick={() => startEdit(contact)}
                              disabled={isBusy}
                            >
                              Edit
                            </Button>
                            <Button
                              size="sm"
                              variant="destructive"
                              onClick={() => handleDelete(contact)}
                              disabled={isBusy}
                            >
                              {isBusy && <Spinner />}
                              Delete
                            </Button>
                          </>
                        )}
                      </div>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}

export default Contacts;
