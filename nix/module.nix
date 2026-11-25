self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.fprintd.validity;
  selfPkgs = self.packages.${pkgs.stdenv.hostPlatform.system};
in
{
  options.services.fprintd.validity = {
    enable = lib.mkEnableOption ''
      fprintd built against libfprint with the native validity/VCSFW driver
      (libfprint MR !626), for Synaptics/Validity match-on-chip sensors such as
      the ThinkPad X280's 06cb:009a'';

    package = lib.mkOption {
      type = lib.types.package;
      default = selfPkgs.fprintd;
      defaultText = lib.literalExpression "thinkpadx280-fprintd.packages.\${system}.fprintd";
      description = "fprintd package (linked against the patched libfprint) to use.";
    };

    libfprint = lib.mkOption {
      type = lib.types.package;
      default = selfPkgs.libfprint;
      defaultText = lib.literalExpression "thinkpadx280-fprintd.packages.\${system}.libfprint";
      description = "Patched libfprint; its udev hwdb (USB autosuspend entries) is installed.";
    };

    fwextFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression "./6_07f_lenovo_mis_qm.xpfwext";
      description = ''
        Optional firmware extension extracted from the vendor Windows driver.
        Not needed on a sensor that has been used before (Windows, python-validity,
        or another Linux install): the driver skips the upload when it fails.
        Installed to /etc/libfprint/validity under its own file name.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !config.services.fprintd.tod.enable;
        message = "services.fprintd.validity and services.fprintd.tod are mutually exclusive.";
      }
    ];

    services.fprintd.enable = true;
    services.fprintd.package = cfg.package;

    services.udev.packages = [ cfg.libfprint ];

    environment.etc = lib.mkIf (cfg.fwextFile != null) {
      "libfprint/validity/${baseNameOf (toString cfg.fwextFile)}".source = cfg.fwextFile;
    };
  };
}
