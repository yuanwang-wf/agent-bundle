{
  description = "Package AI-agent skills and MCP servers once, link them into pi and Cursor";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Used only by the flake checks; core outputs do not depend on it.
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
    }:
    let
      lib = nixpkgs.lib;

      agentBundleLib = import ./lib { inherit lib; };

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      eachSystem = f: lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});

      # A fake package whose skills live in share/skills, so the package-skill
      # copy path can be exercised without a real upstream package.
      fakePkg =
        pkgs:
        pkgs.runCommandLocal "fake-skill-pkg" { } ''
          mkdir -p "$out/share/skills/cat/cat-one"
          echo "---\nname: cat-one\ndescription: Fake.\n---\n\n# Body\n" > "$out/share/skills/cat/cat-one/SKILL.md"
          mkdir -p "$out/share/skills/cat/cat-two"
          echo "---\nname: cat-two\ndescription: Fake2.\n---\n\n# Body\n" > "$out/share/skills/cat/cat-two/SKILL.md"
        '';

      mkBundle = {
        prompts = [
          {
            type = "skill";
            name = "example-skill";
            description = "An example skill shipped by the bundle.";
            body = "Do the example thing.\n";
          }
        ];
        mcpServers = {
          docs = {
            url = "https://example.com/mcp";
            headers = {
              Authorization = "Bearer \${DOCS_TOKEN}";
            };
          };
          local = {
            command = "/bin/echo";
          };
        };
      };
    in
    {
      lib = {
        mkAgentBundlePackage = pkgs: args: agentBundleLib.mkAgentBundlePackage ({ inherit pkgs; } // args);
        inherit (agentBundleLib) normalizeServers validateServers hasMcp;
      };

      homeManagerModules = {
        default = import ./modules/home-manager.nix { inherit lib; };
        agent-bundle = import ./modules/home-manager.nix { inherit lib; };
      };

      checks = eachSystem (
        system: pkgs:
        let
          pkg = agentBundleLib.mkAgentBundlePackage (
            mkBundle // {
              inherit pkgs;
              name = "agent-bundle-check";
            }
          );
        in
        let
          failures = import ./tests/unit.nix {
            inherit lib;
            agentBundle = agentBundleLib;
          };
        in
        {
          unit =
            if failures == [ ] then
              pkgs.runCommandLocal "agent-bundle-unit-tests" { } "touch $out"
            else
              throw "agent-bundle unit tests failed:\n${
                lib.concatMapStringsSep "\n" (
                  t: "- ${t.name}: expected ${builtins.toJSON t.expected}, got ${builtins.toJSON t.result}"
                ) failures
              }";

          bundle-layout = pkgs.runCommandLocal "agent-bundle-check" { } ''
            test -f ${pkg}/pi/mcp.json
            test -f ${pkg}/cursor/mcp.json
            test -f ${pkg}/skills/example-skill/SKILL.md
            touch $out
          '';

          hm-eval =
            let
              hmConfig = home-manager.lib.homeManagerConfiguration {
                inherit pkgs;
                modules = [
                  self.homeManagerModules.default
                  {
                    home = {
                      username = "test";
                      homeDirectory = "/home/test";
                      stateVersion = "25.05";
                    };
                    programs.agent-bundle = mkBundle // {
                      enable = true;
                      skillDirs = [
                        ".pi/agent/skills"
                        ".cursor/skills"
                        ".claude/skills"
                      ];
                      skillSources = [
                        {
                          name = "cat-raw";
                          # Scoped to the pi dir…
                          source = "${fakePkg pkgs}/share/skills/cat";
                          skillDirs = [ ".pi/agent/skills" ];
                        }
                      ];
                      packageSkills = [
                        {
                          # Restricted to the pi skills dir…
                          package = (fakePkg pkgs);
                          subdir = "share/skills/cat";
                          names = [
                            "cat-one"
                            "cat-two"
                          ];
                          skillDirs = [ ".pi/agent/skills" ];
                        }
                      ];
                      # mcpDirs are independent of tools: a dir that no tool
                      # owns is still linked, as is a tool's own parent dir.
                      mcpDirs = [
                        ".pi/agent"
                        ".cursor"
                        ".claude"
                      ];
                    };
                  }
                ];
              };
              files = hmConfig.config.home.file;
            in
            # Per-skill links (mics-skills shape). The package skill is scoped
            # to the pi dir: no cursor/claude links for it.
            assert files ? ".pi/agent/skills/example-skill";
            assert lib.hasPrefix "/nix/store" files.".pi/agent/skills/example-skill".source;
            assert files ? ".pi/agent/skills/cat-one";
            assert files.".pi/agent/skills/cat-one".source == "${fakePkg pkgs}/share/skills/cat/cat-one";
            assert !(files ? ".cursor/skills/cat-one");
            assert !(files ? ".cursor/skills/cat-two");
            assert !(files ? ".claude/skills/cat-one");
            assert files ? ".pi/agent/skills/cat-raw";
            assert files.".pi/agent/skills/cat-raw".recursive;
            assert !(files ? ".cursor/skills/cat-raw");
            assert !(files ? ".claude/skills/cat-raw");
            assert files ? ".pi/agent/mcp.json";
            assert files ? ".cursor/mcp.json";
            assert files ? ".claude/mcp.json";
            pkgs.runCommandLocal "agent-bundle-hm-eval" { } "touch $out";
        }
      );

      formatter = eachSystem (_: pkgs: pkgs.nixfmt-rfc-style);
    };
}
