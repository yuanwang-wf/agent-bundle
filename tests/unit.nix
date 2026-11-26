# Pure-eval unit tests, run with lib.runTests (empty list = all passed).
{ lib, agentBundle }:

let
  inherit (agentBundle) normalizeServers validateServers hasMcp;
  evalPrompt = (import ../lib/skills.nix { inherit lib; }).evalPrompt;

  tryFails = expr: !(builtins.tryEval (builtins.deepSeq expr expr)).success;

  skill =
    {
      name,
      ...
    }:
    {
      type = "skill";
      inherit name;
      description = "a ${name} skill";
      body = "do the ${name} thing";
    };
in
lib.runTests {
  testSkillRequiresDescription = {
    expr = tryFails (evalPrompt {
      type = "skill";
      name = "no-desc";
      body = "x";
    });
    expected = true;
  };

  testSkillRejectsNonSkill = {
    expr = tryFails (evalPrompt {
      type = "agent";
      name = "not-a-skill";
      description = "x";
      body = "x";
    });
    expected = true;
  };

  testSkillFilesMustBeRelative = {
    expr = tryFails (evalPrompt {
      type = "skill";
      name = "bad-file";
      description = "x";
      body = "x";
      files = {
        "../escape.md".text = "x";
      };
    });
    expected = true;
  };

  testServerNameRestricted = {
    expr = tryFails (
      validateServers (normalizeServers {
        "bad name!" = {
          url = "https://example.com";
        };
      })
    );
    expected = true;
  };

  testEveryEnabledServerNeedsCommandOrUrl = {
    expr = tryFails (
      validateServers (normalizeServers {
        local = {
          enabled = true;
        };
      })
    );
    expected = true;
  };

  testHasMcpCursorExcludesDisabled = {
    expr = hasMcp (normalizeServers {
      docs = {
        url = "https://example.com";
      };
      local = {
        command = "/bin/echo";
        enabled = false;
      };
    }) "cursor";
    expected = true;
  };

  testHasMcpPiListsDisabled = {
    expr = hasMcp (normalizeServers {
      local = {
        command = "/bin/echo";
        enabled = false;
      };
    }) "pi";
    expected = true;
  };

  testNormalizedDefaults = {
    expr =
      (normalizeServers {
        docs = {
          url = "https://example.com";
        };
      }).docs.enabled;
    expected = true;
  };
}
