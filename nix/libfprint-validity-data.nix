{
  lib,
  stdenvNoCC,
  fetchFromGitLab,
  python3,
}:

# Runtime blobs (init/reset sequences, TLS keys, firmware signature data) for
# the libfprint validity/VCSFW driver. Generated from python-validity's tables
# by the package's own generator; each .bin carries an HMAC-SHA256 trailer the
# driver checks at load time.
stdenvNoCC.mkDerivation {
  pname = "libfprint-validity-data";
  version = "0.2.0-unstable-2026-09-25";

  src = fetchFromGitLab {
    domain = "gitlab.freedesktop.org";
    owner = "ggiesen";
    repo = "libfprint-validity-data";
    rev = "687c5ea51392582d5bcb1e4fa86eea0832a50c5f";
    hash = "sha256-dqkTzlBvvh+zCrPBhCxUfSgzn2zc+BG4E6A3SLgEK/Q=";
  };

  nativeBuildInputs = [ python3 ];

  buildPhase = ''
    runHook preBuild
    python3 generate_data.py
    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    python3 generate_data.py --verify output/
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    make install PREFIX=$out
    install -Dm644 LICENSE $out/share/licenses/libfprint-validity-data/LICENSE
    runHook postInstall
  '';

  passthru.dataDir = "share/libfprint/validity";

  meta = {
    description = "Sensor data files for the libfprint validity/VCSFW fingerprint driver";
    homepage = "https://gitlab.freedesktop.org/ggiesen/libfprint-validity-data";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
