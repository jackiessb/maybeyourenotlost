import { useState } from "react";
import { Button } from "../components/ui/button";
import { Textarea } from "../components/ui/textarea";
import { Field, FieldDescription, FieldLabel } from "../components/ui/field";
import { Spinner } from "@/components/ui/spinner";
import { toast } from "@/components/ui/toast";

const encourageSomeone = async (encouragement: string) => {
  const response = await fetch("/encouragements", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ text: encouragement }),
  });

  if (!response.ok) {
    throw new Error("Failed to send encouragement");
  }
};

function EncourageSomeone() {
  const [encouragement, setEncouragement] = useState("");
  const [isSubmitting, setIsSubmitting] = useState(false);

  const handleSubmit = async () => {
    setIsSubmitting(true);
    try {
      await encourageSomeone(encouragement);
    } catch {
      toast.add({
        title: "Something went wrong",
        description: "We couldn't send your encouragement. Please try again.",
        type: "error",
      });
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Field>
      <FieldLabel htmlFor="textarea-encouragement">
        Say anything lovely
      </FieldLabel>
      <FieldDescription>Be love to someone else.</FieldDescription>
      <div className="flex flex-col gap-3">
        <Textarea
          id="textarea-encouragement"
          value={encouragement}
          onChange={(e) => setEncouragement(e.target.value)}
        ></Textarea>
        <Button onClick={handleSubmit} disabled={isSubmitting}>
          {isSubmitting && <Spinner></Spinner>}
          Send Encouragement
        </Button>
      </div>
    </Field>
  );
}

export default EncourageSomeone;
