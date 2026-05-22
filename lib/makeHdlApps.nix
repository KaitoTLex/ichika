{ pkgs
, top
, part
, rtlDirs
, constraintsFile ? "constraints.xdc"
, serverLocal
, serverDns       ? ""
, serverUser      ? "vivado"
, sshKey          ? ""
, workBase        ? "/var/lib/vivado-remote"
}:

let
  lib = pkgs.lib;

  synthTcl = pkgs.writeText "ichika-synth.tcl" (builtins.readFile ../scripts/synth.tcl);
  implTcl  = pkgs.writeText "ichika-impl.tcl"  (builtins.readFile ../scripts/impl.tcl);

  configVars = ''
    TOP=${lib.escapeShellArg top}
    PART=${lib.escapeShellArg part}
    SERVER_LOCAL=${lib.escapeShellArg serverLocal}
    SERVER_DNS=${lib.escapeShellArg serverDns}
    SERVER_USER=${lib.escapeShellArg serverUser}
    SSH_KEY=${lib.escapeShellArg sshKey}
    WORK_BASE=${lib.escapeShellArg workBase}
    CONSTRAINTS_FILE=${lib.escapeShellArg constraintsFile}
    SYNTH_TCL=${lib.escapeShellArg "${synthTcl}"}
    IMPL_TCL=${lib.escapeShellArg "${implTcl}"}
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

    SSH_CMD="ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
    if [[ -n "$SSH_KEY" ]]; then
      SSH_CMD="$SSH_CMD -i $SSH_KEY"
    fi

    remote() {
      # shellcheck disable=SC2086
      $SSH_CMD "$SERVER_USER@$SERVER" "$@"
    }

    upload_sources() {
      echo "==> Uploading sources to $SERVER_USER@$SERVER:$WORK_DIR/src/"
      remote "mkdir -p '$WORK_DIR/src'"
      for dir in "''${RTL_DIRS[@]}"; do
        # shellcheck disable=SC2086
        rsync -az --delete -e "$SSH_CMD" "$dir/" "$SERVER_USER@$SERVER:$WORK_DIR/src/"
      done
      if [[ -f "$CONSTRAINTS_FILE" ]]; then
        # shellcheck disable=SC2086
        rsync -az -e "$SSH_CMD" "$CONSTRAINTS_FILE" "$SERVER_USER@$SERVER:$WORK_DIR/constraints.xdc"
      fi
    }
  '';

  synthesize = pkgs.writeShellApplication {
    name = "ichika-synthesize";
    runtimeInputs = [ pkgs.rsync pkgs.openssh ];
    checkPhase = "";
    text = configVars + commonRuntime + ''
      upload_sources
      # shellcheck disable=SC2086
      rsync -az -e "$SSH_CMD" "$SYNTH_TCL" "$SERVER_USER@$SERVER:$WORK_DIR/synth.tcl"
      echo "==> Running synthesis on $SERVER_USER@$SERVER..."
      remote "vivado -mode batch -nojournal -nolog -source '$WORK_DIR/synth.tcl' -tclargs '$TOP' '$PART' '$WORK_DIR/src'"
      echo "==> Synthesis complete."
    '';
  };

  runImpl = pkgs.writeShellApplication {
    name = "ichika-run-impl";
    runtimeInputs = [ pkgs.rsync pkgs.openssh ];
    checkPhase = "";
    text = configVars + commonRuntime + ''
      upload_sources
      # shellcheck disable=SC2086
      rsync -az -e "$SSH_CMD" "$IMPL_TCL" "$SERVER_USER@$SERVER:$WORK_DIR/impl.tcl"
      echo "==> Running implementation pipeline on $SERVER_USER@$SERVER..."
      remote "vivado -mode batch -nojournal -nolog -source '$WORK_DIR/impl.tcl' -tclargs '$TOP' '$PART' '$WORK_DIR/src'"
      # shellcheck disable=SC2086
      rsync -az -e "$SSH_CMD" "$SERVER_USER@$SERVER:$WORK_DIR/src/$TOP.bit" "./$TOP.bit"
      echo "==> Bitstream written to ./$TOP.bit"
    '';
  };

in {
  synthesize = { type = "app"; program = "${synthesize}/bin/ichika-synthesize"; };
  "run-impl" = { type = "app"; program = "${runImpl}/bin/ichika-run-impl"; };
}
