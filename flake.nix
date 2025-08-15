{
  description = "A focused launcher for your desktop — native, fast, extensible";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        
        # Source derivation with patches for Nix compatibility
        vicinae-src = pkgs.stdenv.mkDerivation {
          pname = "vicinae-src";
          version = "dev";
          
          src = ./.;
          
          dontBuild = true;
          
          postPatch = ''
            # Disable CMake API and extension manager targets since we build them separately  
            substituteInPlace cmake/ExtensionApi.cmake \
              --replace "add_custom_target(api DEPENDS $''${API_OUT})" \
                        "# add_custom_target(api DEPENDS $''${API_OUT})"
            
            substituteInPlace cmake/ExtensionManager.cmake \
              --replace "add_custom_target(extension-manager ALL" \
                        "# add_custom_target(extension-manager ALL"
            
            # Patch QRC template to accept runtime path via environment
            substituteInPlace vicinae/resources.qrc.in \
              --replace "@ASSET_PATH@/extension-runtime.js" "@EXTENSION_RUNTIME_PATH@"
            
            # Patch extension manager build to accept API path
            substituteInPlace extension-manager/scripts/build.mjs \
              --replace "'@omnicast/api': '../api/src/'," \
                        "'@omnicast/api': process.env.API_PATH || '../api/src/',"
            
            # Disable ExtensionManager include in root CMakeLists.txt
            substituteInPlace CMakeLists.txt \
              --replace "include(ExtensionManager)" \
                        "# include(ExtensionManager)"
            
            # Patch vicinae CMakeLists.txt to use environment variable for extension runtime path
            substituteInPlace vicinae/CMakeLists.txt \
              --replace 'set(ASSET_PATH ''${CMAKE_CURRENT_SOURCE_DIR}/assets)' \
                        'set(ASSET_PATH ''${CMAKE_CURRENT_SOURCE_DIR}/assets)
if(DEFINED ENV{EXTENSION_RUNTIME_PATH})
    set(EXTENSION_RUNTIME_PATH $ENV{EXTENSION_RUNTIME_PATH})
endif()'
          '';
          
          installPhase = ''
            cp -r . $out
            chmod -R +w $out
          '';
        };
        
        # NPM dependencies for API
        api-node-modules = pkgs.buildNpmPackage {
          pname = "vicinae-api-deps";
          version = "dev";
          
          src = "${vicinae-src}/api";
          
          npmDepsHash = "sha256-Z/zVqWfwzLnGJL2j1jror9xsFqBKVgxgZbAFx7CGLzI="; # Will need to be updated
          
          dontNpmBuild = true;
          
          installPhase = ''
            cp -r node_modules $out
          '';
        };
        
        # NPM dependencies for Extension Manager  
        extension-manager-node-modules = pkgs.stdenv.mkDerivation {
          pname = "vicinae-extension-manager-deps";
          version = "dev";
          
          src = "${vicinae-src}/extension-manager";
          
          nativeBuildInputs = with pkgs; [ nodejs ];
          
          buildPhase = ''
            npm install --package-lock-only
            npm ci
          '';
          
          installPhase = ''
            cp -r node_modules $out
          '';
        };
        
        # Extension API build (simplified for now)
        extension-api = pkgs.stdenv.mkDerivation {
          pname = "vicinae-extension-api";
          version = "dev";
          
          src = "${vicinae-src}/api";
          
          dontBuild = true;
          
          installPhase = ''
            mkdir -p $out
            cp -r src $out/
          '';
        };
        
        # Extension Manager runtime
        extension-manager-runtime = pkgs.writeText "runtime.js" ''
          // Placeholder runtime.js for now
          console.log("Extension manager runtime placeholder");
        '';
        
        # Main vicinae application
        vicinae = pkgs.stdenv.mkDerivation rec {
          pname = "vicinae";
          version = "dev";
          
          src = vicinae-src;
          
          nativeBuildInputs = with pkgs; [
            cmake
            pkg-config
            qt6.wrapQtAppsHook
            protobuf
          ];
          
          buildInputs = with pkgs; [
            qt6.qtbase
            qt6.qtsvg
            qt6.qttools
            qt6.qtwayland
            qt6.qtdeclarative
            qt6.qt5compat
            kdePackages.qtkeychain
            kdePackages.layer-shell-qt
            openssl
            cmark-gfm
            libqalculate
            minizip
            stdenv.cc.cc.lib
            abseil-cpp
            protobuf
            wayland
            rapidfuzz-cpp
          ];
          
          preConfigure = ''
            # Set up environment variables for CMake configure_file
            export EXTENSION_RUNTIME_PATH=${extension-manager-runtime}
          '';
          
          configurePhase = ''
            # Configure CMake with proper runtime path
            cmake -B build \
              -DCMAKE_BUILD_TYPE=Release \
              -DCMAKE_INSTALL_PREFIX=$out
          '';
          
          buildPhase = ''
            cmake --build build -j$NIX_BUILD_CORES
          '';
          
          installPhase = ''
            cmake --install build
          '';
          
          meta = {
            description = "A focused launcher for your desktop — native, fast, extensible";
            homepage = "https://github.com/vicinaehq/vicinae";
            license = pkgs.lib.licenses.gpl3;
            maintainers = [];
            platforms = pkgs.lib.platforms.linux;
          };
        };
      in
      {
        packages.default = vicinae;
        packages.vicinae = vicinae;
        packages.vicinae-src = vicinae-src;
        packages.api-node-modules = api-node-modules;
        packages.extension-manager-node-modules = extension-manager-node-modules;
        packages.extension-api = extension-api;
        packages.extension-manager-runtime = extension-manager-runtime;
        
        apps.default = {
          type = "app";
          program = "${vicinae}/bin/vicinae";
        };

        homeManagerModules.default = { config, lib, pkgs, ... }:
          with lib; let
            cfg = config.services.vicinae;
          in {
            options.services.vicinae = {
              enable = mkEnableOption "vicinae launcher daemon" // {default = false;};

              package = mkOption {
                type = types.package;
                default = vicinae;
                defaultText = literalExpression "vicinae";
                description = "The vicinae package to use.";
              };

              autoStart = mkOption {
                type = types.bool;
                default = true;
                description = "Whether to start the vicinae daemon automatically on login.";
              };
            };

            config = mkIf cfg.enable {
              home.packages = [cfg.package];

              systemd.user.services.vicinae = {
                Unit = {
                  Description = "Vicinae launcher daemon";
                  After = ["graphical-session-pre.target"];
                  PartOf = ["graphical-session.target"];
                };

                Service = {
                  Type = "simple";
                  ExecStart = "${cfg.package}/bin/vicinae server";
                  Restart = "on-failure";
                  RestartSec = 3;
                  Environment = [
                    "PATH=${config.home.profileDirectory}/bin"
                  ];
                };

                Install = mkIf cfg.autoStart {
                  WantedBy = ["graphical-session.target"];
                };
              };
            };
          };
      });
}
