import { cpSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(scriptDirectory, "..");
const sourceFile = resolve(projectRoot, "src", "renderer", "index.html");
const outputFile = resolve(projectRoot, "dist", "renderer", "index.html");

mkdirSync(dirname(outputFile), { recursive: true });
cpSync(sourceFile, outputFile);
