{
  lib,
  libfprint,
  fetchFromGitLab,
  libfprint-validity-data,
}:

# nixpkgs' libfprint, built from libfprint MR !626 (the native validity/VCSFW
# driver, continuing !579). The driver hardcodes /usr/share/libfprint/validity
# as its data directory, which doesn't exist on NixOS, so the store path of
# libfprint-validity-data is patched in ahead of the stock search paths.
let
  dataDir = "${libfprint-validity-data}/${libfprint-validity-data.dataDir}";
in
libfprint.overrideAttrs (old: {
  pname = "libfprint-validity";
  version = "1.94.100-unstable-2026-11-05";

  # Head of https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/626
  src = fetchFromGitLab {
    domain = "gitlab.freedesktop.org";
    owner = "ggiesen";
    repo = "libfprint";
    rev = "5db7da904f74f7fb912d4a18f700a9671d8ab4ac";
    hash = "sha256-9cIx/c1KYud1OkwANM+f0GwrzdlxVsnNTShMf5kq094=";
  };

  postPatch = (old.postPatch or "") + ''
    substituteInPlace libfprint/drivers/validity/validity_data.c \
      --replace-fail '"/usr/share/libfprint/validity",' '"${dataDir}", "/etc/libfprint/validity", "/usr/share/libfprint/validity",'
    # Firmware extension (.xpfwext) lookup: also look in /etc so a user-extracted
    # Lenovo/HP fwext file can be dropped in declaratively via environment.etc.
    substituteInPlace libfprint/drivers/validity/validity_fwext.c \
      --replace-fail '"/usr/share/libfprint/validity",' '"/etc/libfprint/validity", "${dataDir}", "/usr/share/libfprint/validity",'
  '';

  passthru = (old.passthru or { }) // {
    validityData = libfprint-validity-data;
  };

  meta = old.meta // {
    description = "libfprint with the native validity/VCSFW driver (MR !626) for Synaptics/Validity match-on-chip sensors";
    homepage = "https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/626";
  };
})
