# home-manager module: link the packaged skills and mcp.json into the user's
# home.
#
#   <skillDir>/<skill>  ->  $out/skills/<skill>           (prompt skills, from the bundle)
#   <skillDir>/<name>   ->  <pkg>/<subdir>/<name>   (package skills, per-skill, into entry skillDirs)
#   <mcpDir>/mcp.json   ->  $out/<tool>/mcp.json          (when any servers)
#
# Per-skill links, same shape as mics-skills' home.file — they coexist with
# per-file links (flake-prompt) in the same directory. `<skillDir>` and
# `<mcpDir>` come from `programs.agent-bundle.skillDirs` / `.mcpDirs` — one
# per agent harness, same shape as mics-skills' `skillDirs`. Defaults: the
# skills / mcp.json parent dirs of the enabled tools.
{ lib }:

{ config, pkgs, ... }:
let
  cfg = config.programs.agent-bundle;

  agentBundle = import ../lib { inherit lib; };
  skillsLib = import ../lib/skills.nix { inherit lib; };

  normalizedServers = agentBundle.normalizeServers cfg.mcpServers;

  # Names of the prompt skills, known at eval time — prompt skills link from
  # the bundle's skills tree.
  promptSkillNames = map (p: (skillsLib.renderSkill (skillsLib.evalPrompt p)).name) cfg.prompts;

  bundle = agentBundle.mkAgentBundlePackage {
    inherit pkgs;
    inherit (cfg) prompts;
    mcpServers = cfg.mcpServers;
    tools = cfg.tools;
    name = "agent-bundle";
  };

  hasMcp = t: agentBundle.hasMcp normalizedServers t;

  # Prompt skills: every skillDirs entry gets a per-skill link to the bundle.
  promptLinks = lib.listToAttrs (
    lib.concatMap (
      dir:
      map (
        name:
        lib.nameValuePair "${dir}/${name}" {
          source = "${bundle}/skills/${name}";
        }
      ) promptSkillNames
    ) cfg.skillDirs
  );

  # Package skills link straight from each package's skills tree —
  # per-skill, per-dir, the mics-skills pattern. Each entry points at the
  # subtree holding the skills (e.g. "share/skills/workmux"). An entry can
  # restrict the target dirs with its own `skillDirs`; otherwise the module's
  # skillDirs are used (every enabled tool's skills dir).
  packageLinks = lib.listToAttrs (
    lib.concatMap (
      item:
      lib.concatMap (
        dir:
        map (
          name:
          lib.nameValuePair "${dir}/${name}" {
            source = "${item.package}/${item.subdir}/${name}";
          }
        ) item.names
      ) (item.skillDirs or cfg.skillDirs)
    ) cfg.packageSkills
  );

  # mcp.json goes into every mcpDirs entry.
  mcpLinks =
    lib.optionalAttrs (lib.elem "pi" cfg.tools && hasMcp "pi") (
      lib.listToAttrs (
        map (
          dir:
          lib.nameValuePair "${dir}/mcp.json" {
            source = "${bundle}/pi/mcp.json";
          }
        ) cfg.mcpDirs
      )
    )
    // lib.optionalAttrs (lib.elem "cursor" cfg.tools && hasMcp "cursor") (
      lib.listToAttrs (
        map (
          dir:
          lib.nameValuePair "${dir}/mcp.json" {
            source = "${bundle}/cursor/mcp.json";
          }
        ) cfg.mcpDirs
      )
    );

  links = lib.mkMerge [
    promptLinks
    packageLinks
    mcpLinks
  ];
in
{
  options.programs.agent-bundle = {
    enable = lib.mkEnableOption "agent-bundle: package skills and MCP servers for pi and cursor";

    tools = lib.mkOption {
      type = lib.types.listOf (
        lib.types.enum [
          "pi"
          "cursor"
        ]
      );
      default = [
        "pi"
        "cursor"
      ];
      description = "Which agent tools to render mcp.json for and that skills are meant for.";
    };

    mcpDirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # Default: the mcp.json parent dirs of the enabled tools.
      default =
        lib.optionals (lib.elem "pi" config.programs.agent-bundle.tools) [ ".pi/agent" ]
        ++ lib.optionals (lib.elem "cursor" config.programs.agent-bundle.tools) [ ".cursor" ];
      example = lib.literalExpression ''
        [ ".pi/agent" ".claude" ]
      '';
      description = ''
        Directories (relative to `$HOME`) into which each tool's mcp.json is
        symlinked. One entry per agent harness, same shape as mics-skills'
        `skillDirs`. Default: the mcp.json parent dirs of the enabled tools
        (`.pi/agent` for pi, `.cursor` for cursor).
      '';
    };

    skillDirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      # Default: the skills dirs of the enabled tools.
      default =
        lib.optionals (lib.elem "pi" config.programs.agent-bundle.tools) [ ".pi/agent/skills" ]
        ++ lib.optionals (lib.elem "cursor" config.programs.agent-bundle.tools) [ ".cursor/skills" ];
      example = lib.literalExpression ''
        [ ".claude/skills" ".pi/agent/skills" ]
      '';
      description = ''
        Directories (relative to `$HOME`) into which the packaged skills are
        symlinked. One entry per agent harness, the same shape as mics-skills'
        `skillDirs`. Default: the skills dirs of the enabled tools.
      '';
    };

    packageSkills = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          package = lib.mkOption {
            type = lib.types.package;
            description = "Package whose skills tree is linked.";
          };
          subdir = lib.mkOption {
            type = lib.types.str;
            example = "share/skills/workmux";
            description = "Directory inside the package holding the skills (e.g. "share/skills/workmux"); the link is <package>/<subdir>/<name>.";
          };
          names = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = "Skills to link; each must exist at <package>/<subdir>/<name>.";
          };
          skillDirs = lib.mkOption {
            type = lib.types.nullOr (lib.types.listOf lib.types.str);
            default = null;
            example = lib.literalExpression ''[ ".pi/agent/skills" ]'';
            description = "Directories to link this package's skills into; defaults to the module's skillDirs (every enabled tool's skills dir).";
          };
        };
      });
      default = [ ];
      example = lib.literalExpression ''
        [
          {
            package = pkgs.llm-agents.open-code-review;
            subdir = "share/skills/open-code-review";
            names = [ "open-code-review" "open-code-review-delegate" ];
            # Omit to link into every enabled tool's skills dir:
            # skillDirs = [ ".pi/agent/skills" ];
          }
        ]
      '';
      description = ''
        Packages whose skills are symlinked into skillDirs (per-skill links,
        same pattern as mics-skills). Each entry names the package, its skills
        subtree and the skills to link; `<name>` must exist at
        `<package>/<subdir>/<name>` — a missing skill fails the home-manager
        activation. Every entry links into the module's skillDirs unless the
        entry sets its own `skillDirs`, restricting the target dirs.
      '';
    };

    prompts = lib.mkOption {
      type = lib.types.listOf lib.types.raw;
      default = [ ];
      example = lib.literalExpression ''
        [
          {
            type = "skill";
            name = "code-review";
            description = "Review code.";
            body = "…";
          }
        ]
      '';
      description = ''
        Skill attrsets, or functions applied to default args (same ergonomic
        as flake-prompt). Only skills are rendered: instructions, commands and
        agents are not packaged — they are rejected at eval time.
      '';
    };

    mcpServers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
      example = lib.literalExpression ''
        {
          Amplitude = {
            type = "http";
            url = "https://mcp.amplitude.com/mcp";
          };
        }
      '';
      description = ''
        MCP servers written to both tools' mcp.json. Keys must match
        [A-Za-z0-9_-]+; each enabled server needs `command` (stdio) or `url`
        (HTTP). Optional fields (defaults shown): enable=true, enabled=true,
        type=null, command=null, args=[], env={}, headers={}, cwd=null,
        url=null, oauth={}, timeout=null, exposure=null, toolExposure={},
        description=null, packages=[].
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.file = links;
  };
}
