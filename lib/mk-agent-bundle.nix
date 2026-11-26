# $out mirrors the agent home tree:
#   $out/skills/<name>/SKILL.md            (+ extra files)
#   $out/pi/mcp.json                       (when any pi mcpServers are enabled)
#   $out/cursor/mcp.json                   (when any cursor mcpServers are enabled)
# Skills are identical across pi and cursor (both read plain SKILL.md), so
# there is one shared skills tree; the module symlinks it wherever you want.
# `packageSkills` are copied from each package's `share/skills` tree — every
# directory containing a SKILL.md becomes a skill named after that directory.
{ lib }:

let
  skillsLib = import ./skills.nix { inherit lib; };
  mcp = import ./mcp.nix { inherit lib; };

  # Raw server attrsets get the schema defaults applied so authors write
  # only what they mean.
  normalizeServer =
    name: s:
    {
      enable = true;
      enabled = true;
      type = null;
      command = null;
      args = [ ];
      env = { };
      headers = { };
      cwd = null;
      url = null;
      oauth = { };
      timeout = null;
      exposure = null;
      toolExposure = { };
      description = null;
      packages = [ ];
    }
    // s;

  normalizeServers = servers: lib.mapAttrs normalizeServer servers;

  validateServers =
    servers:
    assert lib.assertMsg
      (lib.all (n: builtins.match "[A-Za-z0-9_-]+" n != null) (lib.attrNames servers))
      "agent-bundle: MCP server names may only use letters, digits, _ and -: ${lib.concatStringsSep ", " (lib.attrNames servers)}";
    assert lib.assertMsg (lib.all (s: s.command != null || s.url != null) (
      lib.attrValues (lib.filterAttrs (_: s: s.enable) servers)
    )) "agent-bundle: every enabled MCP server needs either `command` (stdio) or `url` (HTTP)";
    servers;

  hasMcp =
    servers: target:
    let
      enabled =
        if target == "cursor" then
          lib.filterAttrs (_: s: s.enable && s.enabled) servers
        else
          lib.filterAttrs (_: s: s.enable) servers;
    in
    enabled != { };

  installFile =
    pkgs: path: entry:
    let
      src =
        if entry.text != null then pkgs.writeText (builtins.baseNameOf path) entry.text else entry.source;
    in
    ''
      mkdir -p "$out/${builtins.dirOf path}"
      cp ${src} "$out/${path}"
      ${lib.optionalString (entry.executable or false) ''
        chmod +x "$out/${path}"
      ''}
    '';

  # For every package in `packageSkills`, copy every directory containing a
  # SKILL.md under share/skills into the skills tree, named after the skill
  # directory. A package with no share/skills directory at all is an error:
  # the caller passed something whose contract does not match.
  packageSkillCopy = promptSkillNames: packageSkills: ''
    seen="${lib.concatStringsSep " " promptSkillNames}"
    skillMads=""
    for pkg in ${lib.concatStringsSep " " packageSkills}; do
      if [ ! -d "$pkg/share/skills" ]; then
        echo "agent-bundle: package $pkg has no share/skills directory" >&2
        exit 1
      fi
      skillMads="$skillMads $(find "$pkg/share/skills" -name SKILL.md)"
    done
    for skillMd in $skillMads; do
      skillDir=$(dirname "$skillMd")
      name=$(basename "$skillDir")
      if printf '%s\n' $seen | grep -Fx "$name" >/dev/null; then
        echo "agent-bundle: duplicate skill name '$name' (package skills and prompt skills must not collide)" >&2
        exit 1
      fi
      seen="$seen $name"
      mkdir -p "$out/skills/$name"
      cp -R "$skillDir/." "$out/skills/$name/"
    done
  '';
in
{
  inherit normalizeServers validateServers hasMcp;

  mkAgentBundlePackage =
    {
      pkgs,
      name ? "agent-bundle",
      prompts ? [ ],
      packageSkills ? [ ],
      mcpServers ? { },
      tools ? [
        "pi"
        "cursor"
      ],
    }:
    let
      servers = validateServers (normalizeServers mcpServers);
      enabledTools = lib.filter (t: lib.elem t tools) [
        "pi"
        "cursor"
      ];

      rendered = map (p: skillsLib.renderSkill (skillsLib.evalPrompt p)) prompts;

      duplicateNames = lib.filter (n: lib.count (x: x == n) (map (s: s.name) rendered) > 1) (
        lib.unique (map (s: s.name) rendered)
      );

      # (treePath, fileEntry) pairs, one per skill file.
      fileList = lib.concatLists (
        map (
          skill:
          [
            {
              path = "skills/${skill.name}/SKILL.md";
              entry = {
                text = skill.text;
              };
            }
          ]
          ++ map (rel: {
            path = "skills/${skill.name}/${rel}";
            entry = skill.files.${rel};
          }) (lib.attrNames skill.files)
        ) rendered
      );

      # Names of prompt skills, used as the collision baseline for package skills.
      promptSkillNames = map (s: s.name) rendered;

      piMcp =
        if lib.elem "pi" enabledTools then
          mcp {
            inherit pkgs;
            inherit servers;
            target = "pi";
          }
        else
          null;
      cursorMcp =
        if lib.elem "cursor" enabledTools then
          mcp {
            inherit pkgs;
            inherit servers;
            target = "cursor";
          }
        else
          null;
    in
    if duplicateNames == [ ] then
      pkgs.runCommandLocal name { } (
        ''
          mkdir -p "$out/skills"
        ''
        + lib.concatMapStrings (f: installFile pkgs f.path f.entry) fileList
        + lib.optionalString (piMcp != null) ''
          mkdir -p "$out/pi"
          cp ${piMcp} "$out/pi/mcp.json"
        ''
        + lib.optionalString (cursorMcp != null) ''
          mkdir -p "$out/cursor"
          cp ${cursorMcp} "$out/cursor/mcp.json"
        ''
        + packageSkillCopy promptSkillNames packageSkills
      )
    else
      throw "agent-bundle: duplicate skill name(s) in prompt set: ${lib.concatStringsSep ", " (lib.unique duplicateNames)}";
}
