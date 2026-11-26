# agent-bundle

Package AI-agent **skills** and **MCP servers** once, and link the result
into **pi** and **Cursor** — declaratively, through Home Manager.

This is a standalone repo. It renders skills with a small internal engine
instead of depending on flake-prompt, and renders `mcp.json` with a small
internal renderer instead of depending on pi-flake (the two pieces that
need tool-specific knowledge are exactly the two tools this repo packages).
If you already use flake-prompt or pi-flake, their path is unchanged — this
repo coexists; it just does the pi+Cursor slice in one package.

A bundle is a derivation with this tree:

```
$out/
  skills/<name>/SKILL.md                 (+ extra files)
  pi/mcp.json                            (when any pi mcpServers are enabled)
  cursor/mcp.json                        (when any cursor mcpServers are enabled)
```

Skills are identical for pi and cursor (both read plain SKILL.md), so the
tree holds one shared `skills/` directory. The module links it wherever you
point `skillDirs` — e.g. both pi and cursor, or a third harness's dir while
keeping mcp.json for pi and cursor.

## Use it

```nix
# flake.nix
{
  inputs.agent-bundle.url = "github:yuanwang-wf/agent-bundle";
  # …
}
```

```nix
# home-manager
imports = [ inputs.agent-bundle.homeManagerModules.default ];

programs.agent-bundle = {
  enable = true;
  # Default: the skills dirs of the enabled `tools`. Replace/augment with:
  # skillDirs = [ ".pi/agent/skills" ".cursor/skills" ".claude/skills" ];
  # mcpDirs = [ ".pi/agent" ".cursor" ".claude" ];

  prompts = [
    {
      type = "skill";
      name = "code-review";
      description = "Review code against the project style.";
      body = "…";
      files."references/checklist.md".source = ./references/checklist.md;
    }
    # Functions work too; call them with default args:
    # (import ./prompts/commit-style.nix) { scope = "api"; }
  ];

  # Or take skills straight from packages: every directory containing a
  # SKILL.md under <pkg>/share/skills becomes a skill named after that
  # directory (same convention as mics-skills, installAgentSkills-style).
  packageSkills = [
    pkgs.llm-agents.open-code-review
    pkgs.llm-agents.workmux
  ];

  mcpServers = {
    Amplitude = {
      type = "http";
      url = "https://mcp.amplitude.com/mcp";
    };
    docs = {
      url = "https://example.com/mcp";
      headers.Authorization = "Bearer \${DOCS_TOKEN}";
    };
  };
}
```

Home Manager then links each `skillDirs` entry recursively to
`$out/skills`, plus `<mcpDir>/mcp.json` for every `mcpDirs` entry and each
tool with a server set (when the servers exist). The skills are one atomic
directory link per directory (no per-file links), and `mcp.json` is replaced
atomically on each switch.

```nix
programs.agent-bundle = {
  skillDirs = [
    ".pi/agent/skills"
    ".cursor/skills"
    ".claude/skills"
  ];
  mcpDirs = [
    ".pi/agent"
    ".cursor"
    ".claude"
  ];
};
```

## What is packaged — and what is not

- **Skills** are rendered as `SKILL.md` (JSON-scalar frontmatter:
  `name`, `description`, optional `disable-model-invocation`, plus any
  `extraFrontmatter`) — one shared tree, linked into whatever `skillDirs`
  points at. Extra files are copied next to `SKILL.md`.
- **MCP servers** are rendered to `mcp.json` per tool. Pi keeps its
  exposure keys and `$NAME` env interpolation; Cursor gets the same servers
  minus Pi-only keys, with `$NAME` rewritten to `${env:NAME}`. Servers with
  `enabled = false` stay listed for Pi but keep disconnected; Cursor skips
  them entirely.
- **Not packaged**: instructions, commands, and agents. They are rejected
  at eval time with an explicit error — use flake-prompt for those.
- Package skills (`packageSkills`) are merged into the same tree; a name
  shared with a `prompts` skill, or repeated across packages, fails the build
  with an explicit message. A package with no `share/skills` directory is
  likewise an error — the contract didn't match what you passed.
- Skills with the same name are rejected (duplicate).
- Skill file paths must be relative and must not contain `..`.

## mcpServers

| Field | Type | Default | Notes |
|---|---|---|---|
| `enable` | bool | `true` | `false` omits the server entirely |
| `enabled` | bool | `true` | `false`: listed but disconnected (Pi only) |
| `type` | null/`"stdio"`/`"http"`/`"streamable-http"` | `null` | inferred from `command`/`url` |
| `command` | str/package | `null` | stdio; required unless `url` set |
| `args` | list of str/package | `[]` | |
| `env` | attrs | `{}` | `$NAME` refs stay literal (secrets stay out of the store) |
| `headers` | attrs | `{}` | same `$NAME` rule |
| `cwd` | str | `null` | |
| `url` | str | `null` | HTTP endpoint; required unless `command` set |
| `oauth` | attrs | `{}` | |
| `timeout` | int | `null` | per-request seconds (Pi default 60) |
| `exposure` | null/`"codemode"`/`"codemode-deferred"`/`"deferred"`/`"direct"`/`"hidden"` | `null` | Pi only |
| `toolExposure` | attrs | `{}` | Pi only, per-tool overrides |
| `description` | str | `null` | Pi only, one sentence |
| `packages` | list of packages | `[]` | stdio servers needing CLI tools: generates a PATH-setting wrapper |

Server names must match `[A-Za-z0-9_-]+`. A name with a space or other
characters is rejected at eval time.

## Hacking

```
lib/skills.nix           skill eval + SKILL.md emission
lib/mcp.nix              servers -> mcp.json, per tool
lib/mk-agent-bundle.nix  package builder (tree assembly)
modules/home-manager.nix programs.agent-bundle
tests/unit.nix           pure-eval unit tests
```

Checks: `nix flake check` (unit tests, package-layout smoke test,
home-manager-eval).
