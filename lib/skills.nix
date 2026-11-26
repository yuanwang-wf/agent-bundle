# Minimal skills renderer, standalone (no flake-prompt).
#
# Renders flake-prompt-style skill attrsets into the frontmatter+body text
# of a skill's SKILL.md. Agents and commands degrade to skills (same rule
# flake-prompt uses); instructions are not packaged: they are never skills.
{ lib }:

let
  degrade = import ./degrade.nix { inherit lib; };
  keyPattern = "[A-Za-z0-9_-]+";

  # JSON scalar encoding: JSON is a strict subset of YAML 1.2, so strings with
  # colons, quotes, or newlines come out valid as YAML scalars.
  encodeLeaf = v: builtins.toJSON v;

  checkKey =
    context: k:
    lib.assertMsg (
      builtins.match keyPattern k != null
    ) "agent-bundle: invalid frontmatter key '${k}'${context} (allowed: ${keyPattern})";

  toYamlFrontmatter =
    attrs:
    lib.concatMapStrings (k: "${k}: ${encodeLeaf attrs.${k}}\n") (
      # Alphabetical, deterministic.
      lib.sort (a: b: a < b) (lib.attrNames attrs)
    );

  # evalPrompt: a plain attrset (or a function applied to default args) ->
  # validated skill. Body and description are required.
  # Non-skill prompts (agents, commands) degrade to skills — the same rule
  # flake-prompt applies for tools without native support. Instructions are
  # not packaged at all.
  evalPrompt =
    promptOrFn:
    let
      raw = if builtins.isFunction promptOrFn then promptOrFn { } else promptOrFn;
      p0 =
        if (raw.type or "skill") == "skill" then
          raw
        else
          degrade.degradeToSkill raw;
      type = p0.type;
      name = p0.name or null;
      description = p0.description or null;
      body = p0.body or null;
      files = p0.files or { };
      disableModelInvocation = p0.disableModelInvocation or false;
      extraFrontmatter = p0.extraFrontmatter or { };
    in
    assert lib.assertMsg (type == "skill")
      "agent-bundle: only skills are packaged (got type '${type}')";
    assert lib.assertMsg (name != null) "agent-bundle: skill is missing a name";
    assert lib.assertMsg (
      builtins.match "[a-z0-9][a-z0-9-]*" name != null
    ) "agent-bundle: invalid skill name '${name}' (must match [a-z0-9][a-z0-9-]*)";
    assert lib.assertMsg (description != null) "agent-bundle: skill '${name}' is missing a description";
    assert lib.assertMsg (body != null) "agent-bundle: skill '${name}' is missing a body";
    assert lib.assertMsg (lib.all (p: !lib.hasPrefix "/" p && !lib.hasInfix ".." p) (
      lib.attrNames files
    )) "agent-bundle: skill '${name}': file paths must be relative and must not contain '..'";
    assert lib.assertMsg (lib.all (f:
      let t = f.text or null; s = f.source or null; in (t != null) != (s != null)
    ) (lib.attrValues files))
      "agent-bundle: skill '${name}': each file entry must set exactly one of `text` or `source`";
    assert lib.assertMsg (lib.all (k: checkKey " (in extraFrontmatter)" k) (
      lib.attrNames extraFrontmatter
    )) "agent-bundle: skill '${name}': invalid frontmatter key";
    {
      type = "skill";
      inherit
        name
        description
        body
        files
        ;
      inherit disableModelInvocation extraFrontmatter;
    };

  renderSkill =
    p:
    let
      frontmatter = {
        inherit (p) name description;
      }
      // lib.optionalAttrs p.disableModelInvocation { disable-model-invocation = true; }
      // p.extraFrontmatter;
      # Null-valued keys are dropped, as in the fork's mkDoc.
      frontmatter' = lib.filterAttrs (_: v: v != null) frontmatter;
      body = lib.removeSuffix "\n" p.body;
      text =
        let
          fmText = toYamlFrontmatter frontmatter';
        in
        "---\n${fmText}---\n\n${body}\n";
    in
    {
      inherit (p) name;
      text = text;
      files = lib.mapAttrs (
        _: f:
        if (f.text or null) != null then
          { text = f.text; }
        else
          { source = f.source or null; executable = f.executable or false; }
      ) p.files;
    };
in
{
  inherit evalPrompt renderSkill;
}
