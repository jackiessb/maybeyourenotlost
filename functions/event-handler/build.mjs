import * as esbuild from "esbuild";

const watch = process.argv.includes("--watch");

const options = {
  entryPoints: ["src/index.ts"],
  bundle: true,
  platform: "node",
  target: "node20",
  outfile: "dist/index.js",
  format: "cjs",
  sourcemap: true,
  // Injected into the module cache by the Azure Functions Node worker at
  // runtime — not a real package, so it must stay unbundled.
  external: ["@azure/functions-core"],
};

if (watch) {
  const ctx = await esbuild.context(options);
  await ctx.watch();
  console.log("Watching for changes...");
} else {
  await esbuild.build(options);
}
