// @effect-diagnostics nodeBuiltinImport:off -- This desktop-only boundary validates and launches the user's local fork updater.
import { execFileSync, spawn } from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";
import * as NodeProcess from "node:process";
import { LocalForkUpdateStateSchema, type LocalForkUpdateState } from "@t3tools/contracts";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import * as Electron from "electron";

import * as IpcChannels from "../channels.ts";
import * as DesktopIpc from "../DesktopIpc.ts";

const idleState: LocalForkUpdateState = {
  status: "idle",
  message: "Choose your local fork checkout to enable sync and install.",
  conflicts: [],
  pid: null,
  updatedAt: null,
};

const activeStatuses = new Set<LocalForkUpdateState["status"]>([
  "starting",
  "fetching",
  "merging",
  "building",
  "installing",
]);
const activeRuns = new Set<string>();

class LocalForkUpdateOperationError extends Schema.TaggedError<LocalForkUpdateOperationError>()(
  "LocalForkUpdateOperationError",
  {
    operation: Schema.Literals(["get-state", "start", "reveal-folder"]),
    cause: Schema.Defect(),
  },
) {
  override get message(): string {
    return `Local fork updater ${this.operation} failed.`;
  }
}

function resolveRepositoryPath(inputPath: string): string {
  if (NodeProcess.platform !== "darwin") {
    throw new Error("Local fork updates currently support macOS only.");
  }
  if (!NodePath.isAbsolute(inputPath)) {
    throw new Error("Choose an absolute path to the local fork checkout.");
  }

  const root = NodeFS.realpathSync(inputPath);
  const gitRoot = execFileSync("git", ["-C", root, "rev-parse", "--show-toplevel"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  }).trim();
  if (NodeFS.realpathSync(gitRoot) !== root) {
    throw new Error("Choose the root folder of the T3 Code checkout.");
  }
  if (
    !NodeFS.existsSync(NodePath.join(root, "update.sh")) ||
    !NodeFS.existsSync(NodePath.join(root, "apps", "desktop", "package.json"))
  ) {
    throw new Error("The selected folder does not contain the local T3 Code updater.");
  }

  const upstreamRemote = NodeProcess.env.T3CODE_UPSTREAM_REMOTE ?? "origin";
  const upstreamUrl = execFileSync("git", ["-C", root, "remote", "get-url", upstreamRemote], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  }).trim();
  if (!/(?:github\.com[:/]pingdotgg\/t3code)(?:\.git)?$/iu.test(upstreamUrl)) {
    throw new Error(`Git remote '${upstreamRemote}' must point to pingdotgg/t3code.`);
  }
  return root;
}

function statusFile(root: string): string {
  return NodePath.join(root, ".t3", "local-update-status.json");
}

function readState(root: string): LocalForkUpdateState {
  const file = statusFile(root);
  if (!NodeFS.existsSync(file)) return idleState;
  try {
    return Schema.decodeUnknownSync(LocalForkUpdateStateSchema)(
      JSON.parse(NodeFS.readFileSync(file, "utf8")),
    );
  } catch {
    return {
      status: "error",
      message: "Could not read the previous local update status. You can retry the update.",
      conflicts: [],
      pid: null,
      updatedAt: null,
    };
  }
}

function writeState(root: string, state: LocalForkUpdateState): void {
  const file = statusFile(root);
  NodeFS.mkdirSync(NodePath.dirname(file), { recursive: true });
  const temporaryFile = `${file}.${NodeProcess.pid}.tmp`;
  NodeFS.writeFileSync(temporaryFile, JSON.stringify(state));
  NodeFS.renameSync(temporaryFile, file);
}

function processIsRunning(pid: number | null): boolean {
  if (pid === null || !Number.isInteger(pid) || pid < 1) return false;
  try {
    NodeProcess.kill(pid, 0);
    return true;
  } catch (cause) {
    return (cause as NodeJS.ErrnoException).code === "EPERM";
  }
}

function getState(inputPath: string): LocalForkUpdateState {
  const root = resolveRepositoryPath(inputPath);
  const state = readState(root);
  if (activeStatuses.has(state.status) && state.pid !== null && !processIsRunning(state.pid)) {
    return {
      ...state,
      status: "error",
      message: "The updater stopped unexpectedly. Retry to start it again.",
      pid: null,
    };
  }
  return state;
}

async function startUpdate(inputPath: string): Promise<LocalForkUpdateState> {
  const root = resolveRepositoryPath(inputPath);
  const previous = readState(root);
  if (
    activeRuns.has(root) ||
    (activeStatuses.has(previous.status) &&
      (previous.pid === null || processIsRunning(previous.pid)))
  ) {
    return previous;
  }

  const started: LocalForkUpdateState = {
    status: "starting",
    message: "Starting the local fork updater.",
    conflicts: [],
    pid: null,
    updatedAt: null,
  };
  writeState(root, started);

  const script = NodePath.join(root, "update.sh");
  const child = spawn("/bin/bash", [script], {
    cwd: root,
    detached: true,
    stdio: "ignore",
    env: NodeProcess.env,
  });
  activeRuns.add(root);
  child.once("spawn", () => {
    const latest = readState(root);
    if (latest.status === "starting" && latest.pid === null && child.pid !== undefined) {
      writeState(root, { ...latest, pid: child.pid });
    }
  });
  child.once("error", (cause) => {
    activeRuns.delete(root);
    writeState(root, {
      status: "error",
      message: cause.message,
      conflicts: [],
      pid: null,
      updatedAt: null,
    });
  });
  child.once("exit", (code) => {
    activeRuns.delete(root);
    const latest = readState(root);
    if (code !== 0 && activeStatuses.has(latest.status)) {
      writeState(root, {
        status: "error",
        message: "The updater exited before completing. Retry to run it again.",
        conflicts: latest.conflicts,
        pid: null,
        updatedAt: null,
      });
    }
  });
  child.unref();
  return started;
}

export const getLocalForkUpdateState = DesktopIpc.makeIpcMethod({
  channel: IpcChannels.LOCAL_FORK_UPDATE_GET_STATE_CHANNEL,
  payload: Schema.String,
  result: LocalForkUpdateStateSchema,
  handler: Effect.fn("desktop.ipc.localForkUpdates.getState")(function* (repoPath) {
    return yield* Effect.try({
      try: () => getState(repoPath),
      catch: (cause) => new LocalForkUpdateOperationError({ operation: "get-state", cause }),
    });
  }),
});

export const startLocalForkUpdate = DesktopIpc.makeIpcMethod({
  channel: IpcChannels.LOCAL_FORK_UPDATE_START_CHANNEL,
  payload: Schema.String,
  result: LocalForkUpdateStateSchema,
  handler: Effect.fn("desktop.ipc.localForkUpdates.start")(function* (repoPath) {
    return yield* Effect.tryPromise({
      try: () => startUpdate(repoPath),
      catch: (cause) => new LocalForkUpdateOperationError({ operation: "start", cause }),
    });
  }),
});

export const revealLocalForkUpdateFolder = DesktopIpc.makeIpcMethod({
  channel: IpcChannels.LOCAL_FORK_UPDATE_REVEAL_FOLDER_CHANNEL,
  payload: Schema.String,
  result: Schema.Boolean,
  handler: Effect.fn("desktop.ipc.localForkUpdates.revealFolder")(function* (repoPath) {
    const root = yield* Effect.try({
      try: () => resolveRepositoryPath(repoPath),
      catch: (cause) => new LocalForkUpdateOperationError({ operation: "reveal-folder", cause }),
    });
    return yield* Effect.promise(() =>
      Electron.shell.openPath(root).then((error) => error.length === 0),
    );
  }),
});
