import { app, InvocationContext } from "@azure/functions";

app.eventGrid("eventHandler", {
  handler: (event: unknown, context: InvocationContext) => {
    context.log("Event Grid event received:", event);
  },
});
