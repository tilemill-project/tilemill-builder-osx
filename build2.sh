#!/bin/bash

# depends on
# - mapnik-packaging, tm2, tilemill, and s3cmd being pulled down ahead of time
# - see setup.sh for details

THIS_BUILD_ROOT=/Volumes/Flex/mapnik-packaging/osx
cd ${THIS_BUILD_ROOT}
if mkdir LOCKFILE; then
   echo 'no lock found, building'
else
   echo 'lock found, exiting!'
   exit 1
fi

FORCE_BUILD=false
export LDFLAGS="${STDLIB_LDFLAGS} ${LDFLAGS}"
this_day=$(date +"%Y-%m-%d")

while getopts "f" OPT; do
    case $OPT in
        f)
           FORCE_BUILD=true
           ;;
        \?)
            echo "Usage: $0 [-f]" >&2
            echo "  -f         Force a build, even if the script does not want to. You may " >&2
            exit 2
            ;;
    esac
done

function localize_node_mapnik {
    echo 'localizing mapnik'
    cp ${MAPNIK_BIN_SOURCE}/lib/libmapnik.dylib lib/
    cp -r ${MAPNIK_BIN_SOURCE}/lib/mapnik lib/
    install_name_tool -id libmapnik.dylib lib/libmapnik.dylib
    install_name_tool -change /usr/local/lib/libmapnik.dylib @loader_path/libmapnik.dylib lib/_mapnik.node
    for lib in `ls lib/mapnik/input/*input`; do
      install_name_tool -change /usr/local/lib/libmapnik.dylib @loader_path/../../libmapnik.dylib $lib;
    done
    mkdir -p lib/mapnik/share
    echo "
var path = require('path');
module.exports.paths = {
    'fonts': path.join(__dirname, 'mapnik/fonts'),
    'input_plugins': path.join(__dirname, 'mapnik/input')
};
module.exports.env = {
    'ICU_DATA': path.join(__dirname, 'mapnik/share/icu'),
    'GDAL_DATA': path.join(__dirname, 'mapnik/share/gdal'),
    'PROJ_LIB': path.join(__dirname, 'mapnik/share/proj')
};
    " > lib/mapnik_settings.js
    cp -r ${BUILD}/share/proj ./lib/mapnik/share/
    cp -r ${BUILD}/share/gdal ./lib/mapnik/share/
    mkdir -p ./lib/mapnik/share/icu
    cp ${BUILD}/share/icu/*/*dat ./lib/mapnik/share/icu
}

function clean_node_modules {
    rm -rf ./node_modules/mapnik/node_modules/mapnik-vector-tile
    rm -rf ./node_modules/mocha
    find ./node_modules -name test -exec rm -rf {} \;
    find ./node_modules -name build -exec rm -rf {} \;
    find ./node_modules -name src -exec rm -rf {} \;
    find ./node_modules -name deps -exec rm -rf {} \;
    find ./node_modules -name examples -exec rm -rf {} \;
    find ./node_modules -name docs -exec rm -rf {} \;
    #rm -rf ./node_modules/millstone/node_modules/srs/{build,tools,deps,src}
}

# go
echo 'updading mapnik-packaging checkout'
git pull
source MacOSX.sh
./scripts/download_deps.sh
export JOBS=2

# rebuild node if needed
echo 'updading node'
if [ ! -d ${PACKAGES}/node-v${NODE_VERSION} ] || $FORCE_BUILD; then
    ./scripts/build_node.sh
    FORCE_BUILD=true
else
    echo '  skipping node-v${NODE_VERSION} build'
fi

# rebuild mapnik if needed
echo 'updading mapnik'
cd ${THIS_BUILD_ROOT}/mapnik
git describe > mapnik.describe
git pull
if [ `git describe` != `cat mapnik.describe` ] || $FORCE_BUILD; then
    cd ${THIS_BUILD_ROOT}
    ./scripts/build_mapnik.sh
    FORCE_BUILD=true
else
    echo '  skipping mapnik build'
fi

function rebuild_app {
    echo 'clearing node_modules'
    rm -rf ./node_modules
    echo 'cleaning npm cache'
    npm cache clean
    rm -f ./node
    cp `which node` ./
    echo 'running npm install'
    npm install --sqlite=${BUILD}
    echo 'cleaning out uneeded items in node_modules'
    clean_node_modules
    cd ./node_modules/mapnik
    localize_node_mapnik
}

# rebuild tm2 if needed
echo 'updading tm2'
cd ${THIS_BUILD_ROOT}/tm2
git rev-list --max-count=1 HEAD | cut -c 1-7 > tm2.describe
git pull
if [ `git rev-list --max-count=1 HEAD | cut -c 1-7` != `cat tm2.describe` ] || $FORCE_BUILD; then
    rebuild_app
    git rev-list --max-count=1 HEAD | cut -c 1-7 > tm2.describe
    # package
    cd ${THIS_BUILD_ROOT}
    echo 'CURRENT_DIRECTORY="$( cd "$( dirname "$0" )" && pwd )"
    ${CURRENT_DIRECTORY}/tm2/node ${CURRENT_DIRECTORY}/tm2/index.js
    ' > start.command
    chmod +x start.command
    filename=tm2-osx-${this_day}-`cat tm2/tm2.describe`.tar.gz
    echo 'creating $filename'
    tar czfH ${filename} \
      --exclude=.git* \
       start.command tm2
    #ditto -c -k --sequesterRsrc --keepParent --zlibCompressionLevel 9 tm2/ ${ZIP_ARCHIVE}
    UPLOAD="s3://tilemill/dev/${filename}"
    echo 'uploading $UPLOAD'
    ./s3cmd/s3cmd --acl-public put ${filename} ${UPLOAD}
else
    echo '  skipping tm2 build'
fi

# rebuild tilemill if needed
echo 'updading tilemill'
cd ${THIS_BUILD_ROOT}/tilemill
git describe > tilemill.describe
git pull
if [ `git describe` != `cat tilemill.describe` ] || $FORCE_BUILD; then
    rebuild_app
    git describe > tilemill.describe
    cd ${THIS_BUILD_ROOT}/tilemill
    echo "Building TileMill Mac app..."
    cd ./platforms/osx
    make clean
    make package
    make package # works the second time
    plist="$( pwd )/build/Release/TileMill.app/Contents/Info"
    echo "Updating Sparkle appcast feed URL"
    tag=$(git describe --contains $( git rev-parse HEAD ) )
    if [ $tag ]; then
      appcast="http://mapbox.com/tilemill/platforms/osx/appcast2.xml"
    else
      appcast="http://mapbox.com/tilemill/platforms/osx/appcast-dev.xml"
    fi
    defaults write $plist SUFeedURL $appcast
    echo "Ensuring proper permissions on Info.plist..."
    chmod 644 $plist.plist
    echo "Code signing with Developer ID..."
    make sign
    spctl --verbose --assess "$( pwd )/build/Release/TileMill.app" 2>&1
    if [ $? != 0 ]; then
        echo "Code signing invalid. Aborting."
        #exit 1
    fi
    echo "Creating zip archive of Mac app..."
    make zip
    dev_version=$( git describe --tags )
    filename="TileMill-$dev_version.zip"
    UPLOAD="s3://tilemill/dev/${filename}"
    echo 'uploading $UPLOAD'
    ../../../s3cmd/s3cmd --acl-public put TileMill.zip ${UPLOAD}
    # TODO - get sparkle private key on the machine
    #echo 'Yes' | make sparkle
else
    echo '  skipping tilemill build'
fi

cd ${THIS_BUILD_ROOT}
rm -rf LOCKFILE


