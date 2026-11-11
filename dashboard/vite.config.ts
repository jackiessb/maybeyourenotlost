import path from "node:path";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: {
      "@": path.resolve(import.meta.dirname, "./src"),
    },
  },
  server: {
    port: Number(process.env.PORT) || 5174,
    // Aspire injects these when the dashboard is launched via AppHost.cs (WithReference).
    // Proxying locally mirrors the "/admin/contacts" and "/admin/encouragements" YARP
    // routes set up in the deployed container, so app code can always call relative
    // paths and never needs to know the backend URLs itself.
    proxy: {
      ...(process.env["services__contacts-api__http__0"] && {
        "/admin/contacts": {
          target: process.env["services__contacts-api__http__0"],
          changeOrigin: true,
        },
      }),
      ...(process.env["services__encouragement-api__http__0"] && {
        "/admin/encouragements": {
          target: process.env["services__encouragement-api__http__0"],
          changeOrigin: true,
        },
      }),
    },
  },
});
