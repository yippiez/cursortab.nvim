// agentictab snapshot extension for pi.
//
// Before pi executes an `edit` or `write` tool call, snapshot the target
// file's current content into $AGENTICTAB_BACKUP_DIR. The editor never
// restores from these: the agent's edits stay on disk. The snapshot is the
// 3-way MERGE BASE (base vs user buffer vs agent content) and the manifest
// doubles as the touched-file list for the hunk walk. The snapshot for a
// given path is taken at most once per run; the editor empties the backup
// dir at the start of each run, so existence on disk is the dedup marker.
//
// Layout per file: <sha1(abs-path)>.orig (content, only if the file existed)
// and <sha1(abs-path)>.json (metadata, written last as the commit marker).

import * as fs from "node:fs";
import * as path from "node:path";
import * as crypto from "node:crypto";

const MUTATING_TOOLS = new Set(["edit", "write"]);

export default function (pi: any) {
  const backupDir = process.env.AGENTICTAB_BACKUP_DIR;
  if (!backupDir) return;
  const gateBash = process.env.AGENTICTAB_BASH_APPROVAL === "1";

  pi.on("tool_call", async (event: any, ctx: any) => {
    // Bash can mutate files (sed -i, git restore, redirection) and would
    // bypass the proposal system entirely, so every command is routed to the
    // editor for approval. The editor auto-approves read-only commands.
    if (gateBash && event.toolName === "bash") {
      const cmd = (event.input && event.input.command) || "";
      const ok = await ctx.ui.confirm("agentictab-bash", cmd);
      if (!ok) {
        return {
          block: true,
          reason:
            "The user denied this bash command. Never modify files via bash; " +
            "use the edit/write tools for changes, and continue without this command.",
        };
      }
      return;
    }

    if (!MUTATING_TOOLS.has(event.toolName)) return;
    const target = event.input && event.input.path;
    if (!target || typeof target !== "string") return;

    try {
      const abs = path.resolve(process.cwd(), target);
      // sha256 so the editor can derive the same key via vim.fn.sha256()
      const key = crypto.createHash("sha256").update(abs).digest("hex");
      const metaFile = path.join(backupDir, key + ".json");
      if (fs.existsSync(metaFile)) return;

      fs.mkdirSync(backupDir, { recursive: true });
      const existed = fs.existsSync(abs);
      let mtimeMs = null;
      if (existed) {
        mtimeMs = fs.statSync(abs).mtimeMs;
        fs.copyFileSync(abs, path.join(backupDir, key + ".orig"));
      }
      // mtimeMs lets the editor restore the original timestamp after revert,
      // so open buffers don't see a spurious "file changed since reading".
      fs.writeFileSync(metaFile, JSON.stringify({ path: abs, existed, mtimeMs }));
    } catch {
      // Never block the agent on backup failures; revert will fall back to
      // whatever state is recoverable.
    }
  });
}
