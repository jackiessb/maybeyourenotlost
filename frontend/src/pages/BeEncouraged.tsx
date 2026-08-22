import { useState } from "react";
import { Button } from "../components/ui/button";
import { Field, FieldDescription, FieldLabel } from "../components/ui/field";
import { Spinner } from "@/components/ui/spinner";
import { toast } from "@/components/ui/toast";
import { formatPhoneNumber, toE164 } from "@/lib/phone";

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

interface BeEncouragedProps {
  onBackToHome: () => void;
}

function BeEncouraged({ onBackToHome }: BeEncouragedProps) {
  const [number, setNumber] = useState("");
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [isSubmitted, setIsSubmitted] = useState(false);

  const handleSubmit = async () => {
    const phoneNumber = toE164(number);
    if (!phoneNumber) {
      toast.add({
        title: "Invalid phone number",
        description: "Please enter a valid 10-digit US phone number.",
        type: "error",
      });
      return;
    }

    setIsSubmitting(true);
    try {
      await signUp(phoneNumber);
      setIsSubmitted(true);
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

  if (!isSubmitted) {
    return (
      <Field className="pt-10">
        <FieldLabel htmlFor="input-number">
          Enter your phone number below.
        </FieldLabel>
        <FieldDescription>
          We will send encouragement written by an anonymous believer straight
          to your phone once a week.
        </FieldDescription>
        <FieldDescription>
          <span className="italic">United States only</span> (for now).
        </FieldDescription>
        <div className="flex flex-col gap-3">
          <input
            id="input-number"
            type="tel"
            value={number}
            placeholder="(123) 456-7890"
            autoComplete="tel-national"
            inputMode="numeric"
            maxLength={14}
            onChange={(e) => setNumber(formatPhoneNumber(e.target.value))}
            className="flex h-9 w-full rounded-2xl border border-transparent bg-input px-2.5 py-2 text-base transition-[color,box-shadow] duration-200 outline-none placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/30 md:text-sm"
          />
          <Button onClick={handleSubmit} disabled={isSubmitting}>
            {isSubmitting && <Spinner></Spinner>}
            Be Encouraged
          </Button>
        </div>
      </Field>
    );
  } else {
    return (
      <Field className="pt-15">
        <FieldLabel htmlFor="input-number">
          You are loved, of infinite worth, and seen by an Almighty God.
        </FieldLabel>
        <FieldDescription>
          If you have encouragement to share with another believer, feel free to
          click below and encourage someone.
        </FieldDescription>
        <Button onClick={onBackToHome}>Back To Home</Button>
      </Field>
    );
  }
}

export default BeEncouraged;
