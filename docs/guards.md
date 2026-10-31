# The guards

Three PreToolUse hooks. They deny, and they never rewrite a command. The block applies to the model only. You can still run anything yourself in a real terminal.

## pre-tool-use-guard.sh

Runs on Bash and PowerShell. It is pure bash, with no python and no jq, so a missing tool cannot switch it off.

| Check | Denies |
|---|---|
| 1 | Force push: `--force`, `-f`, grouped flags like `-fu`, `+refspec`, and `git -C dir push` |
| 2 | Skipping hooks: `--no-verify`, `git commit -n` |
| 3 | Recursive delete of home or root, in bash, PowerShell and cmd form |
| 4 | `git reset --hard` chained with a push |
| 5 | Printing a secret-shaped variable (`echo $API_KEY`, `printenv`, `process.env`, `os.environ`) |
| 6 | `python3` where it is not installed. Turns itself off when python3 exists |
| 7 | A quoted Windows path that ends in a backslash, which breaks bash quoting |
| 8 | Reading a secret file through a shell verb (`cat`, `sed`, `base64`, `cp`, `curl -d @file`, `python -c`, and more) |

Check 8 first takes the command apart: subshells, `bash -c` bodies, `VAR=x` prefixes, wrappers like `timeout` and `sudo`, braces and escapes. It then judges each argument. `grep` passes only in count, list or quiet form, so `grep -c API_KEY .env` is the safe way to probe a file. A path that comes from a variable is denied, because the guard cannot tell what it names.

A commit message is data, so its quoted body is blanked before the checks run. A message can name `--no-verify`. Flags outside the quotes are still checked, and a `$(...)` inside a message is checked too, because bash runs it.

## file-io-guard.sh

Runs on Write, Edit, MultiEdit, Read, Grep and NotebookEdit.

- **Rule A:** a Write that replaces a memory file of 2048 bytes or more with under half its size is denied. An edit changes part of a file. It does not halve it. `MEMORY_REWRITE_OK=1` is the escape hatch. "Memory file" means any `.md` under a folder named `memory`.
- **Rule B:** no Read of a secret file, and no Grep in content mode on one. Count and file-list modes stay allowed.

## deploy-preflight-guard.sh

Runs on Bash and PowerShell. It blocks a Vercel or Railway deploy unless the nearest `CLAUDE.md` holds a `Deploy target:` line. It works out which project is being deployed from the last `cd`, `--cwd`, or the positional path. It sees through `npx`, `bunx`, `pnpm dlx`, `yarn dlx`, `@latest` and `VAR=x` prefixes.

To add a platform, extend `RE_VERCEL` and `RE_RAILWAY` in the script.

## secret-paths.sh

The one definition of a secret file, shared by both guards. If it goes missing, both fail closed. To add a pattern, add a sample path to `SECRET_PATH_SAMPLES` in the same edit. The tests then prove both guards deny it.

Covered: `.env` and `.env.*`, `*.env`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.asc`, `*.gpg`, `*.kdbx`, SSH private keys, `.credentials.json`, `.npmrc`, `.pgpass`, `.pypirc`, `.netrc`, `.git-credentials`, and AWS, Azure, gcloud, kube and docker credential stores.

Exempt: names ending `.example`, `.sample`, `.template`, and `*.pub`.

## Known limits

The guards stop accidents and common shapes. They are not a sandbox. A determined process can get past them, and these are the known ways.

- **Pipes across segments.** `curl -H "x: $TOKEN" url | tee out` is allowed. Blocking it would also block every ordinary authenticated curl.
- **Bare `env` and bare `printenv`** are allowed. They are common and usually harmless.
- **Indirection.** `eval`, base64-decoded commands, a script file that does the forbidden thing, and git aliases are not seen. The guard reads the command line, not what it runs.
- **Interpreters reading a built path.** `python -c` is judged on path-shaped pieces. A path assembled from strings inside the code is not seen.
- **Secrets deep in a folder.** A recursive search checks the top level of the folder. A secret two folders down is not seen.
- **Windows 8.3 short names** such as `CREDEN~1` are not resolved.
- **`env.production`** (no leading dot) is allowed. Covering it would also block `env.d.ts`.
- **MCP tools** are not covered. The guards see Bash, PowerShell and the file tools.
- **Content.** Rule B works on file names. A secret in `notes.txt` is not detected.
- **Deploys** cover Vercel and Railway only.

Some of these are deliberate. A gate that cries wolf gets switched off, and a switched-off gate catches nothing.
