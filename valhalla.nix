{
  symlinkJoin,
  makeWrapper,
  valhalla,
  libsodium,
}:

# nixpkgs' Valhalla links libsodium without a runpath to it and fails to start.
symlinkJoin {
  name = "valhalla-${valhalla.version}";
  paths = [ valhalla ];
  nativeBuildInputs = [ makeWrapper ];
  postBuild = ''
    for bin in $out/bin/*; do
      wrapProgram "$bin" --prefix LD_LIBRARY_PATH : ${libsodium}/lib
    done
  '';
}
