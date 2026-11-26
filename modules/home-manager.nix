# home-manager module: link the packaged skills and mcp.json for pi and
# cursor into the user's home.
#
#   <skillDir>/<skill>/ (recursive) <- $out/skills
#   <mcpDir>/mcp.json               <- $out/<tool>/mcp.json          (when any servers)
#
# `<skillDir>` and `<mcpDir>` come from `programs.agent-bundle.skillDirs` and
# `.mcpDirs` — one per agent harness, the same shape as mics-skills'
# `skillDirs`. Defaults: the skills / mcp.json parent dirs of the enabled tools.
{ lib }:

{ config, pkgs, ... }:
let
  cfg = config.programs.agent-bundle;

  agentBundle = import ../lib { inherit lib; };

  normalizedServers = agentBundle.normalizeServers cfg.mcpServers;

  bundle = agentBundle.mkAgentBundlePackage {
    inherit pkgs;
    inherit (cfg) prompts packageSkills;
    mcpServers = cfg.mcpServers;
    tools = cfg.tools;
    name = "agent-bundle";
  };

  hasMcp = t: agentBundle.hasMcp normalizedServers t;

  # Skills go into every skillDirs entry; mcp.json into every mcpDirs entry.
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
    (lib.listToAttrs (
      map (
        dir:
        lib.nameValuePair dir {
          source = "${bundle}/skills";
          recursive = true;
        }
      ) cfg.skillDirs
    ))
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
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression ''
        [ pkgs.llm-agents.open-code-review ]
      '';
      description = ''
        Packages whose skills are linked into skillDirs. Every directory
        containing a SKILL.md under `share/skills` in each package becomes a
        skill named after that directory; the package is copied into the
        bundle at build time. Fails loudly if a package has no share/skills
        directory or two skills collide in name.
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
