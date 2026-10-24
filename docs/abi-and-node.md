# LoongArch ABI and Node.js notes

## e_flags: 0x3 vs 0x43

LoongArch ELF headers carry the ABI version in `e_flags`:

| `e_flags` | ABI | readelf description |
| --- | --- | --- |
| `0x3` | ABI1.0 | `DOUBLE-FLOAT, OBJ-v0` |
| `0x43` | ABI2.0 | `DOUBLE-FLOAT, OBJ-v1` |

Check any binary or shared object with:

```sh
LC_ALL=C readelf -h /path/to/binary | grep Flags
```

On the lab machine:

- `/bin/ls` → `0x43` (system userspace is ABI2.0)
- `/opt/node22/bin/node` (Loongnix FTP 22.16.0) → `0x3`
- `/opt/node22-abi2/bin/node` (loong64/node 22.23.3) → `0x43`
- dsh's `koffi.node` → `0x43`

An ABI2.0 binary will not load on an ABI1.0 userspace. The reverse is not a
problem for ABI1.0 binaries, but dsh's ABI2.0 native addon is the constraint.

## The Node 22.16 trap

The Node 22.16.0 tarball historically served from the Loongnix FTP is **ABI1.0
(`0x3`)**. It can run, but:

1. dsh's koffi native addon is ABI2.0 and cannot load under it;
2. Node 22.16 predates `import.meta.main` (added in 22.18 / 24.2), so dsh's
   `lib/bin.js` reaches `if (import.meta.main) await runCli();` and exits
   silently with status 0 and no output.

Use a current build from <https://github.com/loong64/node/releases>:

```text
https://github.com/loong64/node/releases/download/v22.23.3/node-v22.23.3-linux-loong64.tar.xz
```

The installer also downloads the matching `.sha256` asset and verifies it.

If an older Node must be used, `install/dsh-node22-shim.mjs` imports `runCli`
from the adjacent `bin.js` and calls it explicitly. The installer selects the
shim automatically when `import.meta.main` is unavailable.

## Agent packages

The Loongnix registry mirrors packages with loong64 native artifacts:

```text
https://registry.loongnix.cn:5873
```

Versions used and verified:

| Package | Version | Runtime |
| --- | --- | --- |
| `@openai/codex` | 0.162.0 | Node (JS entry + native helper) |
| `opencode-ai` | 1.19.0 | Native LoongArch ELF (`bin/opencode.exe`), no Node |
| `@deepseek-ai/dsh` | 0.2.1-rc.2 | Node + ABI2.0 native addon |

Install under an ABI2.0 Node prefix so npm selects the right native artifacts:

```sh
NODE_PREFIX=/opt/node22-abi2
PATH="$NODE_PREFIX/bin:$PATH" \
  "$NODE_PREFIX/bin/npm" install -g --registry https://registry.loongnix.cn:5873 \
  @openai/codex@0.162.0 opencode-ai@1.19.0 @deepseek-ai/dsh@latest
```

`install/install-loongarch-agents.sh` automates all of this and leaves the
system Node (`/usr/bin/node`, v20.19.2 on the lab machine) untouched.

## Verification

```sh
/opt/node22-abi2/bin/node -v                       # v22.23.3
LC_ALL=C readelf -h /opt/node22-abi2/bin/node | grep Flags   # 0x43
codex --version                                    # codex-cli 0.162.0
opencode --version
dsh --version                                      # 0.2.1-rc.2
```
