# starting place
cd /Volumes/Flex/

# setup mapnik-packaging
git clone https://github.com/mapnik/mapnik-packaging.git
cd mapnik-packaging/osx
source MacOSX.sh
./scripts/download_deps.sh
./scripts/build_core_deps.sh
./scripts/build_deps_optional.sh
./scripts/build_node.sh
./scripts/build_protobuf.sh
./scripts/build_python_versions.sh
./scripts/build_mapnik.sh

# setup s3cmd
git clone https://github.com/s3tools/s3cmd.git

# setup tilemill and tm2
git clone https://github.com/mapbox/tilemill.git
git clone https://github.com/mapbox/tm2.git