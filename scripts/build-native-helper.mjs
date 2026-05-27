import { existsSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const projectRoot = resolve(scriptDirectory, "..");
const sourceFile = resolve(projectRoot, "native", "macos-recorder", "Sources", "MacOSRecorder", "main.swift");
const probeSourceFile = resolve(projectRoot, "native", "macos-window-probe", "main.swift");
const outputDirectory = resolve(projectRoot, "dist", "native");
const swiftModuleCache = resolve(projectRoot, ".swift-module-cache");
const clangModuleCache = resolve(projectRoot, ".clang-module-cache");
const targetBinary = resolve(outputDirectory, "macos-recorder");
const probeTargetBinary = resolve(outputDirectory, "macos-window-probe");

mkdirSync(outputDirectory, { recursive: true });
mkdirSync(swiftModuleCache, { recursive: true });
mkdirSync(clangModuleCache, { recursive: true });

execFileSync(
  "swiftc",
  [
    "-O",
    "-target", "arm64-apple-macosx15.0",
    sourceFile,
    "-o", targetBinary
  ],
  {
    stdio: "inherit",
    env: {
      ...process.env,
      SWIFT_MODULECACHE_PATH: swiftModuleCache,
      CLANG_MODULE_CACHE_PATH: clangModuleCache
    }
  }
);

execFileSync(
  "swiftc",
  [
    "-O",
    "-target", "arm64-apple-macosx15.0",
    probeSourceFile,
    "-o", probeTargetBinary
  ],
  {
    stdio: "inherit",
    env: {
      ...process.env,
      SWIFT_MODULECACHE_PATH: swiftModuleCache,
      CLANG_MODULE_CACHE_PATH: clangModuleCache
    }
  }
);

if (!existsSync(targetBinary)) {
  throw new Error(`Expected native helper at ${targetBinary}`);
}

if (!existsSync(probeTargetBinary)) {
  throw new Error(`Expected native window probe at ${probeTargetBinary}`);
}
