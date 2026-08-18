import { useState } from "react";
import { Button } from "../components/ui/button";
import { Textarea } from "../components/ui/textarea";
import { Field, FieldDescription, FieldLabel } from "../components/ui/field";

const encourageSomeone = async (encouragement: string) => {
  await fetch("/encouragements", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ encouragement }),
  });
};

function EncourageSomeone() {
  const [encouragement, setEncouragement] = useState("");

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
        <Button onClick={() => encourageSomeone(encouragement)}>
          Send Encouragement
        </Button>
      </div>
    </Field>
  );
}

export default EncourageSomeone;
