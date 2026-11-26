# agent-bundle library: skill/MCP packaging (mkAgentBundlePackage) plus the
# capture helpers (skillFromDir / promptFromMarkdown) and the agent→skill
# degradation, so prompt-set modules can share the same code.
{ lib }:
let
  core = import ./mk-agent-bundle.nix { inherit lib; };
  skills = import ./skills.nix { inherit lib; };
  markdown = import ./markdown.nix { inherit lib; };
  degrade = import ./degrade.nix { inherit lib; };
in
{
  inherit (core) normalizeServers validateServers hasMcp mkAgentBundlePackage;
  inherit (skills) evalPrompt renderSkill;
  inherit (markdown) parseMarkdownDoc promptFromMarkdown skillFromDir;
  inherit (degrade) degradeToSkill;
}
