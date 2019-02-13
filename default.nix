{ obelisk ? import ./.obelisk/impl {}
, pkgs ? obelisk.nixpkgs, ... } @ args:

let

  reflex-platform = obelisk.reflex-platform;
  inherit (pkgs) lib;
  haskellLib = pkgs.haskell.lib;

  # Some dependency thunks needed
  repos = {

    # Point to OS fork of groundhog
    groundhog = pkgs.fetchFromGitHub {
      owner = "obsidiansystems";
      repo = "groundhog";
      rev = "f68d1c91a92a9514e771fc432ec2ea9cf93c78af";
      sha256 = "196mq9ncgr8gcnk1p86390v54ixswhwak5wq4630rynyfxw8xmgw";
    };

    # bytestring-trie in hackage doesn’t support base 4.11+
    bytestring-trie = pkgs.fetchFromGitHub {
      owner = "obsidiansystems";
      repo = "bytestring-trie";
      rev = "27117ef4f9f01f70904f6e8007d33785c4fe300b";
      sha256 = "103fqr710pddys3bqz4d17skgqmwiwrjksn2lbnc3w7s01kal98a";
    };

    # New version, recently added to hackage
    constraints-extras = pkgs.fetchFromGitHub {
      owner = "obsidiansystems";
      repo = "constraints-extras";
      rev = "841fafd55ae16e6c367ce0f87fc077b173a25667";
      sha256 = "18hx7nfqfl945pkr8m2mflndszd1f1wgrwb8mpjz8yx5pqhyy41f";
    };

    # Newly added to hackage
    aeson-gadt-th = pkgs.fetchFromGitHub {
      owner = "obsidiansystems";
      repo = "aeson-gadt-th";
      rev = "5aabb547893b8a1140ddad4fba5a266db1d08fbe";
      sha256 = "0sywn3w7ph7b7r0byjz7c9cy41hb8p3ym8qljg1bd99d92hj3sig";
    };

    # Newly added to hackage
    postgresql-lo-stream = pkgs.fetchFromGitHub {
      owner = "obsidiansystems";
      repo = "postgresql-lo-stream";
      rev = "33e1a64c1f65d7d1e26d6d08d2ddb85eb795f94c";
      sha256 = "0n2cmmplljq3z3n0piyiq4vvx8d48byi5isr520aq6dv35j5ixim";
    };

    dependent-sum-aeson-orphans = pkgs.fetchFromGitHub {
      owner = "obsidiansystems";
      repo = "dependent-sum-aeson-orphans";
      rev = "9c995128f416cc27dbd28d7dca1b6de4ac6c9c6d";
      sha256 = "1cinfpchl4g3lpkwbcg03n5h25fj340g0n7bbr7hcx5nx0cwbzbc";

    };
  };

  # Local packages. We override them below so that other packages can use them.
  rhyolitePackages = {
    rhyolite-common = ./common;
    rhyolite-aeson-orphans = ./aeson-orphans;
    rhyolite-backend = ./backend;
    rhyolite-backend-db = ./backend-db;
    rhyolite-backend-db-gargoyle = ./backend-db-gargoyle;
    rhyolite-backend-snap = ./backend-snap;
    rhyolite-datastructures = ./datastructures;
    rhyolite-frontend = ./frontend;
  };

  # srcs used for overrides
  overrideSrcs = rhyolitePackages // {
    groundhog = repos.groundhog + /groundhog;
    groundhog-postgresql = repos.groundhog + /groundhog-postgresql;
    groundhog-th = repos.groundhog + /groundhog-th;
    bytestring-trie = repos.bytestring-trie;
    constraints-extras = repos.constraints-extras;
    aeson-gadt-th = repos.aeson-gadt-th;
    postgresql-lo-stream = repos.postgresql-lo-stream;
    dependent-sum-aeson-orphans = repos.dependent-sum-aeson-orphans;
  };

  # You can use these manually if you don’t want to use rhyolite.project.
  # It will be needed if you need to combine with multiple overrides.
  haskellOverrides = lib.foldr lib.composeExtensions  (_: _: {}) [
    (self: super: lib.mapAttrs (name: path: self.callCabal2nix name path {}) overrideSrcs)
    (self: super: {
      bytestring-trie = haskellLib.dontCheck super.bytestring-trie;
    })
  ];

in obelisk // {

  inherit haskellOverrides;

  # Function similar to obelisk.project that handles overrides for you.
  project = base: projectDefinition:
    obelisk.project base ({...}@args:
      let def = projectDefinition args;
      in def // {
        overrides = lib.composeExtensions haskellOverrides (def.overrides or (_: _: {}));
      });

  # Used to build this project. Should only be needed by CI, devs.
  proj = obelisk.reflex-platform.project ({ pkgs, ... }@args: {
    overrides = haskellOverrides;
    packages = {
      rhyolite-common = ./common;
      rhyolite-aeson-orphans = ./aeson-orphans;
      rhyolite-backend = ./backend;
      rhyolite-backend-db = ./backend-db;
      rhyolite-backend-db-gargoyle = ./backend-db-gargoyle;
      rhyolite-backend-snap = ./backend-snap;
      rhyolite-datastructures = ./datastructures;
      rhyolite-frontend = ./frontend;
    };
    shells = rec {
      ghc = [
        "rhyolite-backend"
        "rhyolite-backend-db"
        "rhyolite-backend-db-gargoyle"
        "rhyolite-backend-snap"
      ] ++ ghcjs;
      ghcjs = [
        "rhyolite-aeson-orphans"
        "rhyolite-common"
        "rhyolite-datastructures"
        "rhyolite-frontend"
      ];
    };
    tools = ghc: [ pkgs.postgresql ];
  });

}
