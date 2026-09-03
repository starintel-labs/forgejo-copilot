{
  description = "forgejo-copilot: @copilot task-execution bot for Forgejo as a long-running SWI-Prolog service on prolog-rlm";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # Public prolog-rlm runtime, consumed as an external SWI-Prolog pack.
    # This repository owns no prolog-rlm code; bump the pin deliberately.
    prolog-rlm = {
      url = "github:lost-rob0t/prolog-rlm/8e7b00934824f329acb373ea086be6294f67f9d3";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, prolog-rlm }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        swiProlog = pkgs.swi-prolog;
        prologRlm = prolog-rlm.packages.${system}.prolog-rlm;
        prologRlmPack = "${prologRlm}/share/swi-prolog/pack";
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [ swiProlog prologRlm pkgs.git ];
          SWIPL_PACK_PATH = prologRlmPack;
          shellHook = ''
            echo "forgejo-copilot devshell: swipl $(swipl --version 2>&1 | cut -d' ' -f3), prolog-rlm pack on SWIPL_PACK_PATH"
          '';
        };

        checks = {
          spec-verify = pkgs.runCommand "forgejo-copilot-spec-verify" {
            nativeBuildInputs = [ swiProlog prologRlm ];
            SWIPL_PACK_PATH = prologRlmPack;
          } ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            cd "${self}"
            swipl -q -s verify/verify.pl && touch "$out"
          '';

          unit-tests = pkgs.runCommand "forgejo-copilot-unit-tests" {
            nativeBuildInputs = [ swiProlog prologRlm ];
            SWIPL_PACK_PATH = prologRlmPack;
          } ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            cd "${self}"
            swipl -q -s test/run_tests.pl && touch "$out"
          '';

          smoke = pkgs.runCommand "forgejo-copilot-smoke" {
            nativeBuildInputs = [ swiProlog prologRlm ];
            SWIPL_PACK_PATH = prologRlmPack;
          } ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            cd "${self}"
            swipl -q -s bin/copilot-demo.pl && touch "$out"
          '';
        };
      });
}
