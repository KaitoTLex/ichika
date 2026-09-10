{
  pkgs,
  top,
  part,
  rtlDirs ? [ ],
  sourceDirs ? rtlDirs,
  constraintsFiles ? [ "constraints.xdc" ],
  serverLocal,
  serverDns ? "",
  serverUser ? "runner",
  sshKey ? "",
  workBase ? "/var/lib/vivado-remote",
  synthTcl ? null,
  implTcl ? null,
  implTclArgs ? [ ],
  projectTcl ? null,
  jobs ? 8,
  projectName ? top,
  artifactDir ? "artifacts",
  rsyncExclude ? [ ".git/" ".direnv/" "artifacts/" "result" ],
  keepRemote ? false,
}:

assert sourceDirs != [ ];
assert projectTcl == null || (synthTcl == null && implTcl == null);

let
  lib = pkgs.lib;
  projectMode = projectTcl != null;

  resolvedSynthTcl =
    if projectMode
    then pkgs.writeText "ichika-project-build.tcl" (builtins.readFile ../scripts/project-build.tcl)
    else if synthTcl != null
    then synthTcl
    else pkgs.writeText "ichika-synth.tcl" (builtins.readFile ../scripts/synth.tcl);

  resolvedImplTcl =
    if projectMode
    then pkgs.writeText "ichika-project-build.tcl" (builtins.readFile ../scripts/project-build.tcl)
    else if implTcl != null
    then implTcl
    else pkgs.writeText "ichika-impl.tcl" (builtins.readFile ../scripts/impl.tcl);

  implTclArgsLiteral = lib.escapeShellArgs implTclArgs;
  rsyncExcludeLiteral = lib.escapeShellArgs (map (pattern: "--exclude=${pattern}") rsyncExclude);
  projectSynthArgs =
    if projectMode
    then lib.escapeShellArgs [ projectTcl (toString jobs) "synth" ]
    else "";
  projectImplArgs =
    if projectMode
    then lib.escapeShellArgs [ projectTcl (toString jobs) "impl" ]
    else implTclArgsLiteral;

  configVars = ''
    TOP=${lib.escapeShellArg top}
    PART=${lib.escapeShellArg part}
    PROJECT_NAME=${lib.escapeShellArg projectName}
    ARTIFACT_BASE=${lib.escapeShellArg artifactDir}
    SERVER_LOCAL=${lib.escapeShellArg serverLocal}
    SERVER_DNS=${lib.escapeShellArg serverDns}
    SERVER_USER=${lib.escapeShellArg serverUser}
    SSH_KEY=${lib.escapeShellArg sshKey}
    WORK_BASE=${lib.escapeShellArg workBase}
    KEEP_REMOTE=${if keepRemote then "1" else "0"}
    CONSTRAINTS_FILES=(${lib.escapeShellArgs constraintsFiles})
    SYNTH_TCL=${lib.escapeShellArg "${resolvedSynthTcl}"}
    IMPL_TCL=${lib.escapeShellArg "${resolvedImplTcl}"}
    SOURCE_DIRS=(${lib.escapeShellArgs sourceDirs})
    RSYNC_EXCLUDES=(${rsyncExcludeLiteral})
  '';

  commonRuntime = ''
    BUILD_ID="''${ICHIKA_BUILD_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
    if [[ ! "$BUILD_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
      echo "ICHIKA_BUILD_ID may contain only letters, digits, '.', '_' and '-'" >&2
      exit 2
    fi
    if [[ ! "$PROJECT_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
      echo "projectName may contain only letters, digits, '.', '_' and '-'" >&2
      exit 2
    fi
    WORK_DIR="$WORK_BASE/$PROJECT_NAME/$BUILD_ID"
    REMOTE_ARTIFACT_DIR="$WORK_DIR/artifacts"
    LOCAL_ARTIFACT_DIR="$ARTIFACT_BASE/$BUILD_ID"

    SERVER="''${ICHIKA_SERVER:-}"
    if [[ -z "$SERVER" ]]; then
      if [[ "''${ICHIKA_USE_DNS:-0}" == "1" && -n "$SERVER_DNS" ]]; then
        SERVER="$SERVER_DNS"
      else
        SERVER="$SERVER_LOCAL"
      fi
    fi

    SSH_ARGS=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes)
    [[ -n "$SSH_KEY" ]] && SSH_ARGS+=(-i "$SSH_KEY")
    SSH_E="ssh$(printf ' %q' "''${SSH_ARGS[@]}")"

    remote() { ssh "''${SSH_ARGS[@]}" "$SERVER_USER@$SERVER" "$@"; }
    TMP_STAGE=""
    cleanup_local() {
      if [[ -n "$TMP_STAGE" ]]; then
        rm -rf "$TMP_STAGE"
      fi
    }
    trap cleanup_local EXIT

    upload_sources() {
      echo "==> Uploading sources to $SERVER_USER@$SERVER:$WORK_DIR/src/"
      local stage
      stage="$(mktemp -d)"
      TMP_STAGE="$stage"
      for dir in "''${SOURCE_DIRS[@]}"; do
        if [[ ! -d "$dir" ]]; then
          echo "Source directory does not exist: $dir" >&2
          return 2
        fi
        rsync -a "''${RSYNC_EXCLUDES[@]}" "$dir/" "$stage/"
      done
      remote "rm -rf '$WORK_DIR' && mkdir -p '$WORK_DIR/src' '$REMOTE_ARTIFACT_DIR'"
      rsync -az --delete -e "$SSH_E" "$stage/" "$SERVER_USER@$SERVER:$WORK_DIR/src/"
      rm -rf "$stage"
      TMP_STAGE=""
      for cf in "''${CONSTRAINTS_FILES[@]}"; do
        if [[ -f "$cf" ]]; then
          rsync -az -e "$SSH_E" "$cf" "$SERVER_USER@$SERVER:$WORK_DIR/$(basename "$cf")"
        else
          echo "==> Skipping missing constraint: $cf"
        fi
      done
    }

    download_artifacts() {
      mkdir -p "$LOCAL_ARTIFACT_DIR"
      rsync -az --delete -e "$SSH_E" "$SERVER_USER@$SERVER:$REMOTE_ARTIFACT_DIR/" "$LOCAL_ARTIFACT_DIR/"
      echo "==> Artifacts written to $LOCAL_ARTIFACT_DIR"
      if [[ "$KEEP_REMOTE" == "0" ]]; then
        remote "rm -rf '$WORK_DIR'"
      fi
    }
  '';

  synthesize = pkgs.writeShellApplication {
    name = "ichika-synthesize";
    runtimeInputs = [
      pkgs.rsync
      pkgs.openssh
    ];
    text =
      configVars
      + commonRuntime
      + ''
        upload_sources
        rsync -az -e "$SSH_E" "$SYNTH_TCL" "$SERVER_USER@$SERVER:$WORK_DIR/synth.tcl"
        echo "==> Running synthesis on $SERVER_USER@$SERVER..."
        remote "cd '$WORK_DIR' && vivado -mode batch -journal '$REMOTE_ARTIFACT_DIR/vivado.jou' -log '$REMOTE_ARTIFACT_DIR/vivado.log' -source '$WORK_DIR/synth.tcl' -tclargs '$TOP' '$PART' '$WORK_DIR/src' ${projectSynthArgs}"
        remote "if [ -f '$WORK_DIR/synth.dcp' ]; then cp '$WORK_DIR/synth.dcp' '$REMOTE_ARTIFACT_DIR/'; fi; if [ -d '$WORK_DIR/reports' ]; then cp -r '$WORK_DIR/reports/.' '$REMOTE_ARTIFACT_DIR/'; fi"
        download_artifacts
        echo "==> Synthesis complete."
      '';
  };

  runImpl = pkgs.writeShellApplication {
    name = "ichika-run-impl";
    runtimeInputs = [
      pkgs.rsync
      pkgs.openssh
    ];
    text =
      configVars
      + commonRuntime
      + ''
        upload_sources
        rsync -az -e "$SSH_E" "$IMPL_TCL" "$SERVER_USER@$SERVER:$WORK_DIR/impl.tcl"
        echo "==> Running implementation pipeline on $SERVER_USER@$SERVER..."
        remote "cd '$WORK_DIR' && vivado -mode batch -journal '$REMOTE_ARTIFACT_DIR/vivado.jou' -log '$REMOTE_ARTIFACT_DIR/vivado.log' -source '$WORK_DIR/impl.tcl' -tclargs '$TOP' '$PART' '$WORK_DIR/src' ${projectImplArgs}"
        remote "if [ -f '$WORK_DIR/src/$TOP.bit' ]; then cp '$WORK_DIR/src/$TOP.bit' '$REMOTE_ARTIFACT_DIR/'; fi; if [ -d '$WORK_DIR/reports' ]; then cp -r '$WORK_DIR/reports/.' '$REMOTE_ARTIFACT_DIR/'; fi"
        download_artifacts
        echo "==> Implementation complete."
      '';
  };

in
{
  synthesize = {
    type = "app";
    program = "${synthesize}/bin/ichika-synthesize";
  };
  "run-impl" = {
    type = "app";
    program = "${runImpl}/bin/ichika-run-impl";
  };
}
