# Minimal skills renderer, standalone (no flake-prompt).
#
# Renders flake-prompt-style skill attrsets into the frontmatter+body text
# of a skill's SKILL.md, per tool. Commands, agents and instructions are
# rejected: this repo packages skills and mcp.json only.
{ lib }:

let
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
  evalPrompt =
    promptOrFn:
    let
      raw = if builtins.isFunction promptOrFn then promptOrFn { } else promptOrFn;
      type = raw.type or "skill";
      name = raw.name or null;
      description = raw.description or null;
      body = raw.body or null;
      files = raw.files or { };
      disableModelInvocation = raw.disableModelInvocation or false;
      extraFrontmatter = raw.extraFrontmatter or { };
    in
    assert lib.assertMsg (type == "skill")
      "agent-bundle: only skills are packaged (got type '${type}'); commands, agents and instructions belong to flake-prompt";
    assert lib.assertMsg (name != null) "agent-bundle: skill is missing a name";
    assert lib.assertMsg (
      builtins.match "[a-z0-9][a-z0-9-]*" name != null
    ) "agent-bundle: invalid skill name '${name}' (must match [a-z0-9][a-z0-9-]*)";
    assert lib.assertMsg (description != null) "agent-bundle: skill '${name}' is missing a description";
    assert lib.assertMsg (body != null) "agent-bundle: skill '${name}' is missing a body";
    assert lib.assertMsg (lib.all (p: !lib.hasPrefix "/" p && !lib.hasInfix ".." p) (
      lib.attrNames files
    )) "agent-bundle: skill '${name}': file paths must be relative and must not contain '..'";
    assert lib.assertMsg (lib.all (f: (f.text != null) != (f.source or null != null)) (
      lib.attrValues files
    )) "agent-bundle: skill '${name}': each file entry must set exactly one of `text` or `source`";
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
      body = lib.removeSuffix "\n" p.body;
      text =
        let
          fmText = toYamlFrontmatter frontmatter;
        in
        "---\n${fmText}---\n\n${body}\n";
    in
    {
      inherit (p) name;
      text = text;
      files = lib.mapAttrs (
        _: f: if f.text != null then { inherit (f) text; } else { inherit (f) source executable; }
      ) p.files;
    };
in
{
  inherit evalPrompt renderSkill;
}
