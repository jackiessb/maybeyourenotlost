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

interface EncourageSomeoneProps {
  onBackToHome: () => void;
}

function EncourageSomeone({ onBackToHome }: EncourageSomeoneProps) {
  const [encouragement, setEncouragement] = useState("");
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [isSubmitted, setIsSubmitted] = useState(false);

  const handleSubmit = async () => {
    setIsSubmitting(true);
    try {
      await encourageSomeone(encouragement);
      setIsSubmitted(true);
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

  if (!isSubmitted) {
    return (
      <Field>
        <FieldLabel htmlFor="textarea-encouragement">
          Type a message below for a believer who is struggling to find hope,
          and needs a reason to carry on trusting in Jesus to sustain them.
        </FieldLabel>
        <FieldDescription>
          The most helpful messages are personal, grounded in truth and hope
          without preaching or oversimplifying their pain.{" "}
        </FieldDescription>
        <div className="flex flex-col gap-3">
          <Textarea
            className="bg-input max-h-16 overflow-auto"
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
  } else {
    return (
      <>
        <Field className="pt-8">
          <FieldLabel htmlFor="textarea-encouragement">Thank you.</FieldLabel>
          <FieldDescription>
            Your words will be used to lift someone else up.{" "}
          </FieldDescription>
          <FieldDescription>
            If you are struggling and need to be encouraged, consider
            subscribing to our registry to recieve encouragement weekly.{" "}
          </FieldDescription>
          <Button onClick={onBackToHome}>Back To Home</Button>
        </Field>
      </>
    );
  }
}

export default EncourageSomeone;
