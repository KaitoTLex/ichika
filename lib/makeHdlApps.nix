{
  pkgs,
  top,
  part,
  rtlDirs,
  constraintsFiles ? [ "constraints.xdc" ],
  serverLocal,
  serverDns ? "",
  serverUser ? "runner",
  sshKey ? "",
  workBase ? "/var/lib/vivado-remote",
  synthTcl ? null,
  implTcl ? null,
  implTclArgs ? [ ],
}:

let
  lib = pkgs.lib;

  resolvedSynthTcl =
    if synthTcl != null
    then synthTcl
    else pkgs.writeText "ichika-synth.tcl" (builtins.readFile ../scripts/synth.tcl);

  resolvedImplTcl =
    if implTcl != null
    then implTcl
    else pkgs.writeText "ichika-impl.tcl" (builtins.readFile ../scripts/impl.tcl);

  implTclArgsLiteral = lib.escapeShellArgs implTclArgs;

  configVars = ''
    TOP=${lib.escapeShellArg top}
    PART=${lib.escapeShellArg part}
    SERVER_LOCAL=${lib.escapeShellArg serverLocal}
    SERVER_DNS=${lib.escapeShellArg serverDns}
    SERVER_USER=${lib.escapeShellArg serverUser}
    SSH_KEY=${lib.escapeShellArg sshKey}
    WORK_BASE=${lib.escapeShellArg workBase}
    CONSTRAINTS_FILES=(${lib.escapeShellArgs constraintsFiles})
    SYNTH_TCL=${lib.escapeShellArg "${resolvedSynthTcl}"}
    IMPL_TCL=${lib.escapeShellArg "${resolvedImplTcl}"}
    RTL_DIRS=(${lib.escapeShellArgs rtlDirs})
  '';

  commonRuntime = ''
    WORK_DIR="$WORK_BASE/$TOP"

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

    upload_sources() {
      echo "==> Uploading sources to $SERVER_USER@$SERVER:$WORK_DIR/src/"
      remote "mkdir -p '$WORK_DIR/src'"
      for dir in "''${RTL_DIRS[@]}"; do
        rsync -az --delete -e "$SSH_E" "$dir/" "$SERVER_USER@$SERVER:$WORK_DIR/src/"
      done
      for cf in "''${CONSTRAINTS_FILES[@]}"; do
        if [[ -f "$cf" ]]; then
          rsync -az -e "$SSH_E" "$cf" "$SERVER_USER@$SERVER:$WORK_DIR/$(basename "$cf")"
        fi
      done
    }
  '';

  synthesize = pkgs.writeShellApplication {
    name = "ichika-synthesize";
    runtimeInputs = [
      pkgs.rsync
      pkgs.openssh
    ];
    checkPhase = "";
    text =
      configVars
      + commonRuntime
      + ''
        upload_sources
        rsync -az -e "$SSH_E" "$SYNTH_TCL" "$SERVER_USER@$SERVER:$WORK_DIR/synth.tcl"
        echo "==> Running synthesis on $SERVER_USER@$SERVER..."
        remote "vivado -mode batch -nojournal -nolog -source '$WORK_DIR/synth.tcl' -tclargs '$TOP' '$PART' '$WORK_DIR/src'"
        echo "==> Synthesis complete."
      '';
  };

  runImpl = pkgs.writeShellApplication {
    name = "ichika-run-impl";
    runtimeInputs = [
      pkgs.rsync
      pkgs.openssh
    ];
    checkPhase = "";
    text =
      configVars
      + commonRuntime
      + ''
        upload_sources
        rsync -az -e "$SSH_E" "$IMPL_TCL" "$SERVER_USER@$SERVER:$WORK_DIR/impl.tcl"
        echo "==> Running implementation pipeline on $SERVER_USER@$SERVER..."
        remote "vivado -mode batch -nojournal -nolog -source '$WORK_DIR/impl.tcl' -tclargs '$TOP' '$PART' '$WORK_DIR/src' ${implTclArgsLiteral}"
        rsync -az -e "$SSH_E" "$SERVER_USER@$SERVER:$WORK_DIR/src/$TOP.bit" "./$TOP.bit"
        echo "==> Bitstream written to ./$TOP.bit"
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
