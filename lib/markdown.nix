# Capture existing prompt markdown (Claude/Codex-style commands, SKILL.md
# files) into canonical prompts, so prompt content maintained outside Nix
# can be imported without duplicating it.
#
# Frontmatter parsing supports:
#   - single-line scalars (bare or quoted; "true"/"false"/"null"/"~" unquoted)
#   - folded plain scalars that wrap over several lines
#   - YAML block scalars (| literal, > folded; with the trailing -/+ indicators)
#   - one level of nested keys (e.g. metadata.version)
# Anything deeper is an authoring error.
{ lib }:

let
  spaces = n: lib.concatStringsSep "" (builtins.genList (_: " ") n);

  leadingIndent =
    line:
    let
      m = builtins.match "( *)(.*)" line;
    in
    if m == null then 0 else builtins.stringLength (builtins.head m);

  stripIndent = line: lib.removePrefix (spaces (leadingIndent line)) line;

  stripCommonIndent =
    lines:
    let
      indents = map (line: if stripIndent line == "" then 999999 else leadingIndent line) lines;
      min = builtins.foldl' (a: b: if b < a then b else a) 999999 indents;
    in
    map (
      line:
      let
        i = leadingIndent line;
      in
      if i >= min && min < 999999 then lib.removePrefix (spaces min) line else line
    ) lines;

  unquoteBare =
    v:
    if v == "true" then
      true
    else if v == "false" then
      false
    else if v == "null" || v == "~" then
      null
    else
      v;

  unquoteQuoted =
    v:
    let
      m = builtins.match "\"(.*)\"|'(.*)'" v;
    in
    if m == null then v else lib.findFirst (x: x != null) null m;

  isQuoted = v: lib.hasPrefix "\"" v || lib.hasPrefix "'" v;

  blockScalarMode =
    v:
    if v == "|" || v == "|-" || v == "|+" then
      "literal"
    else if v == ">" || v == ">-" || v == ">+" then
      "folded"
    else
      null;

  # Collapse any run of whitespace to a single space. (builtins.split takes
  # a regex and interleaves matches into the result, so it is not a drop-in
  # whitespace-collapser; split on " " and filter empties instead.)
  collapseSpaces =
    s:
    let
      withSpaces = builtins.replaceStrings [ "\t" "\r" "\n" ] [ " " " " " " ] s;
      parts = lib.filter (x: x != "") (lib.splitString " " withSpaces);
    in
    lib.concatStringsSep " " parts;

  parseKey =
    line:
    let
      trimmed = stripIndent line;
      m = builtins.match "([A-Za-z0-9_-]+): *(.*)" trimmed;
    in
    if m == null then null else { key = lib.head m; value = lib.last m; };

in
rec {
  takeWhile =
    pred: xs:
    if xs == [ ] then
      xs
    else if pred (lib.head xs) then
      [ (lib.head xs) ] ++ takeWhile pred (lib.tail xs)
    else
      [ ];

  takeContinuation =
    lines:
    let
      cont = takeWhile (
        line: stripIndent line != "" && leadingIndent line > 0
      ) lines;
    in
    {
      continuation = stripCommonIndent cont;
      rest = lib.drop (builtins.length cont) lines;
    };

  go =
    acc: lines:
    if lines == [ ] then
      acc.frontmatter
    else
      let
        first = lib.head lines;
        rest = lib.tail lines;
        trimmed = stripIndent first;
        parsed = parseKey first;
      in
      if trimmed == "" then
        go acc rest
      else if parsed == null then
        throw "agent-bundle: frontmatter line unparseable: ${first}"
      else if parsed.value == "" then
        # `key:` with no same-line value — nested map, or a bare null.
        let
          contd = takeContinuation rest;
          continuation = contd.continuation;
          innerRest = contd.rest;
          isNested =
            continuation != [ ]
            && builtins.all (
              line:
              let
                m = parseKey line;
              in
              m != null && m.value != ""
            ) continuation;
        in
        if isNested then
          let
            nested = lib.listToAttrs (
              map (
                line:
                let
                  m = parseKey line;
                  value =
                    if isQuoted m.value then
                      unquoteQuoted m.value
                    else
                      unquoteBare m.value;
                in
                lib.nameValuePair m.key value
              ) continuation
            );
          in
          go (acc // { frontmatter = acc.frontmatter // { "${parsed.key}" = nested; }; }) innerRest
        else
          go (acc // { frontmatter = acc.frontmatter // { "${parsed.key}" = null; }; }) innerRest
      else if blockScalarMode parsed.value != null then
        # YAML block scalar on this line — collect indented continuation lines.
        let
          mode = blockScalarMode parsed.value;
          contd = takeContinuation rest;
          continuation = contd.continuation;
          innerRest = contd.rest;
        in
        if mode == "literal" then
          let
            value = lib.removeSuffix "\n" (lib.concatStringsSep "\n" continuation);
          in
          go (acc // { frontmatter = acc.frontmatter // { "${parsed.key}" = value; }; }) innerRest
        else
          let
            content = lib.concatStringsSep " " continuation;
            value = collapseSpaces content;
          in
          go (acc // { frontmatter = acc.frontmatter // { "${parsed.key}" = value; }; }) innerRest
      else if isQuoted parsed.value then
        # quoted scalar — no continuation allowed
        let
          contd = takeContinuation rest;
          continuation = contd.continuation;
          innerRest = contd.rest;
        in
        if continuation != [ ] then
          throw "agent-bundle: quoted frontmatter value cannot span lines (key '${parsed.key}')"
        else
          go (acc // { frontmatter = acc.frontmatter // { "${parsed.key}" = unquoteQuoted parsed.value; }; }) innerRest
      else
        # bare scalar — may fold over indented continuation lines
        let
          contd = takeContinuation rest;
          continuation = contd.continuation;
          innerRest = contd.rest;
          value =
            if continuation == [ ] then
              unquoteBare parsed.value
            else
              let
                content = parseKeyContinuationAndFirst parsed continuation;
              in
              content;
        in
        go (acc // { frontmatter = acc.frontmatter // { "${parsed.key}" = value; }; }) innerRest;

  parseKeyContinuationAndFirst =
    parsed: continuation:
    let
      content = lib.concatStringsSep " " ([ parsed.value ] ++ continuation);
    in
    collapseSpaces content;

  # parseYamlBlock : list of frontmatter lines -> attrsOf (string | nested attrs)
  parseYamlBlock = lines: go { frontmatter = { }; } lines;

  # parseMarkdownDoc : str -> { frontmatter : attrsOf (string | nested attrs); body : str; }
  parseMarkdownDoc =
    text:
    let
      lines = lib.splitString "\n" text;
      rest = lib.tail lines;
      endIdx = lib.lists.findFirstIndex (l: l == "---") null rest;
      noFrontmatter = {
        frontmatter = { };
        body = text;
      };
    in
    if lines == [ ] || lib.head lines != "---" || endIdx == null then
      noFrontmatter
    else
      {
        frontmatter = parseYamlBlock (lib.take endIdx rest);
        body = lib.concatStringsSep "\n" (
          dropWhile (l: l == "") (lib.drop (endIdx + 1) rest)
        );
      };

  dropWhile =
    pred: xs:
    if xs == [ ] || !pred (lib.head xs) then xs else dropWhile pred (lib.tail xs);

  # Capture a single markdown prompt file (or literal text).
  #
  #   promptFromMarkdown {
  #     type ? "skill";           # skill | command | agent | instructions
  #     name ? <frontmatter name>; # ...or from the file's own frontmatter
  #     source ? null;            # path to the .md file
  #     text ? null;              # ... or its contents directly
  #     keepExtraFrontmatter ? true;  # carry unknown scalars (author, ...) through
  #     ...                       # any other canonical prompt fields, merged last
  #   }
  #
  # Frontmatter mapping: description -> description, argument-hint ->
  # argumentHint (commands only); remaining scalars land in extraFrontmatter
  # unless keepExtraFrontmatter = false. Explicit fields win over captured ones.
  promptFromMarkdown =
    {
      type ? "skill",
      name ? null,
      source ? null,
      text ? null,
      keepExtraFrontmatter ? true,
      ...
    }@args:
    let
      raw =
        if text != null then
          text
        else if source != null then
          builtins.readFile source
        else
          throw "agent-bundle: promptFromMarkdown: one of `source` or `text` is required";
      doc = parseMarkdownDoc raw;
      fm = doc.frontmatter;
      name =
        if args ? name && args.name != null then args.name
        else if fm ? name then fm.name
        else throw "agent-bundle: promptFromMarkdown: pass \`name\` or let the frontmatter provide it";
      extra = removeAttrs fm [
        "name"
        "description"
        "argument-hint"
      ];
      captured = {
        inherit type name;
        body = doc.body;
      }
      // lib.optionalAttrs (fm ? description) { inherit (fm) description; }
      // lib.optionalAttrs (type == "command" && fm ? "argument-hint") {
        argumentHint = fm."argument-hint";
      }
      // lib.optionalAttrs (keepExtraFrontmatter && extra != { }) { extraFrontmatter = extra; };
    in
    captured
    // removeAttrs args [
      "type"
      "name"
      "source"
      "text"
      "keepExtraFrontmatter"
    ];

  # Capture a whole skill directory: SKILL.md plus every other file in the
  # directory (references/, scripts/, ...) as skill `files`.
  skillFromDir =
    {
      dir,
      name ? builtins.unsafeDiscardStringContext (baseNameOf dir),
      exclude ? [ "README.md" ],
      ...
    }@args:
    let
      allFiles = lib.filesystem.listFilesRecursive dir;
      # Keys (skill name, relative file names) must be context-free strings:
      # `dir` may be "${flakeInput}/..." and attribute names cannot refer to
      # store paths. The file *sources* keep their context, so the
      # dependency on the input is preserved.
      rel =
        path: builtins.unsafeDiscardStringContext (lib.removePrefix "${toString dir}/" (toString path));
      extraFiles = lib.filter (
        p: rel p != "SKILL.md" && !lib.elem (rel p) exclude
      ) allFiles;
    in
    promptFromMarkdown (
      {
        type = "skill";
        inherit name;
        source = dir + "/SKILL.md";
        files = lib.listToAttrs (
          map (p: lib.nameValuePair (rel p) { source = p; }) extraFiles
        );
      }
      // removeAttrs args [
        "dir"
        "name"
        "exclude"
      ]
    );
}
