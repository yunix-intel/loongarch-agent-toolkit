// Fallback launcher for Node versions that lack import.meta.main (< 22.18).
// Node 22.16 silently does nothing when bin.js is executed, because its
// self-start guard `if (import.meta.main) await runCli();` is never entered.
// The installer places this file next to bin.js and points the wrapper here
// only on such Node builds. Node 22.23.3 does not need it.
import { runCli } from "./bin.js";
await runCli();
