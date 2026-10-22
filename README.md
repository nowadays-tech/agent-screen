# Agent Screen

A Mac menu bar app that sits between Claude Code agents and the Anthropic API. It forwards all traffic unchanged and has Superagent's [Security-One](https://www.superagent.sh/docs/models/security-one) model score the outside text each agent reads. Any tool result that scores 0.70 or more is flagged. Flags are the only thing it records.

It only watches. It never blocks or changes a request.

## Use

```sh
bin/build                          # builds build/Agent Screen.app
cp -R "build/Agent Screen.app" ~/Applications/
open ~/Applications/"Agent Screen.app"
```

The menu shows the proxy URL, `http://127.0.0.1:8977`. Click it to copy it. Point an agent at it:

```sh
ANTHROPIC_BASE_URL=http://127.0.0.1:8977 claude
```

For a Multica agent, add `ANTHROPIC_BASE_URL` to its custom env with `multica agent env set`. The subscription login works through the proxy, so no API key is needed.

Then pick **Set Superagent API Key…** in the menu. Without a key, the app passes traffic through and scores nothing. The key is stored in `~/Library/Application Support/Agent Screen/superagent-api-key` with mode 0600.

Pick **Open at Login** so the app comes back after a restart. An agent pointed at the URL fails while the app is not running.

## What it screens

Tool results that carry text from outside the machine:

- `WebFetch` and `WebSearch`
- MCP tools (`mcp__*`)
- `Bash` commands that run `gh`, `multica`, `curl`, or `wget`

It skips everything else, such as `Read`, `Skill`, and `git`: their text is local, or instructions by design. Skipped results never leave the machine.

Claude Code resends the whole conversation every turn. The app scores each result once per run. It splits results over 60,000 characters into chunks and scores each chunk.

## Flags

A flag turns the menu bar icon into a warning shield with a count. The menu lists the latest ten flags. Each flag is one JSON line in `~/Library/Application Support/Agent Screen/flags.jsonl`:

```json
{"excerpt":"…first 500 characters…","score":0.95,"session":"<Claude Code session id>","source":"https://example.com/page","time":"2026-10-22T13:08:18Z","tool":"WebFetch"}
```

The app never logs headers. The agent's OAuth token passes through it, so it listens on `127.0.0.1` only.

## Develop

```sh
swift test
```

The tests stub both upstreams. They cover request parsing, passthrough of streamed replies, cancelling upstream when the client hangs up, which tool results are screened, the threshold, and retry after a failed score.
