import { useState } from "react";
import { Button } from "../components/ui/button";
import { Field, FieldDescription, FieldLabel } from "../components/ui/field";
import { Spinner } from "@/components/ui/spinner";
import { toast } from "@/components/ui/toast";

const signUp = async (number: string) => {
  const response = await fetch("/contacts", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ phoneNumber: number }),
  });

  if (!response.ok) {
    throw new Error("Failed to sign up");
  }
};

function BeEncouraged() {
  const [number, setNumber] = useState("");
  const [isSubmitting, setIsSubmitting] = useState(false);

  const handleSubmit = async () => {
    setIsSubmitting(true);
    try {
      await signUp(number);
    } catch {
      toast.add({
        title: "Something went wrong",
        description: "We couldn't sign you up. Please try again.",
        type: "error",
      });
    } finally {
      setIsSubmitting(false);
    }
  };

  return (
    <Field>
      <FieldLabel htmlFor="input-number">Your phone number</FieldLabel>
      <FieldDescription>
        We'll text you a little encouragement now and then.
      </FieldDescription>
      <div className="flex flex-col gap-3">
        <input
          id="input-number"
          type="tel"
          value={number}
          onChange={(e) => setNumber(e.target.value)}
          className="flex h-9 w-full rounded-2xl border border-transparent bg-input/50 px-2.5 py-2 text-base transition-[color,box-shadow] duration-200 outline-none placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30 md:text-sm"
        />
        <Button onClick={handleSubmit} disabled={isSubmitting}>
          {isSubmitting && <Spinner></Spinner>}
          Be Encouraged
        </Button>
      </div>
    </Field>
  );
}

export default BeEncouraged;
