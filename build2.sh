#!/bin/bash
set -e -u

FATAL=true
FORCE=false
FORCE_MAPNIK=false
FORCE_TM=false
FORCE_NODE=false
FORCE_TM2=false
CXX11=false
BUILD_POSTFIX=""
BUILD_BASE=/Volumes/Flex
THIS_BUILD_ROOT=${BUILD_BASE}/mapnik-packaging/osx
LOCKFILE=${THIS_BUILD_ROOT}/lock-dir

# depends on
# - mapnik-packaging, tm2, tilemill, and s3cmd being pulled down ahead of time
# - see setup.sh for details

function exit_if {
  if [ $FATAL = true ]; then
    rm -rf ${LOCKFILE}
    kill -INT $$
  else
    echo "***"
    echo "***experienced error: $1 but continuing"
    echo "***"
  fi
}

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
    # ensure we have only one mapnik included
    rm -rf ./node_modules/tilelive-mapnik/node_modules/mapnik
    rm -rf ./node_modules/mapnik/node_modules/mapnik-vector-tile
    rm -rf ./node_modules/mocha
    rm -rf ./node_modules/jshint
    rm -rf ./node_modules/JSV/jsdoc-toolkit
    # disabled since this can break git merge
    #rm -rf ./test
    # special case contextify
    # https://github.com/mapbox/tilemill-builder-osx/issues/27
    rm -rf ./NW_TMP/
    CONTEXIFY_LOCATION="./node_modules/bones/node_modules/jquery/node_modules/jsdom/node_modules/contextify/build/Release"
    cp "${CONTEXIFY_LOCATION}/contextify.node" ./contextify.node
    NWMATCHER_LOCATION="./node_modules/bones/node_modules/jquery/node_modules/jsdom/node_modules/nwmatcher/src"
    cp -r ${NWMATCHER_LOCATION} ./NW_TMP/
    find ./node_modules -name test | xargs rm -rf;
    find ./node_modules -name tests | xargs rm -rf;
    find ./node_modules -name tmp | xargs rm -rf;
    find ./node_modules -name build | xargs rm -rf;
    find ./node_modules -name src | xargs rm -rf;
    find ./node_modules -name deps | xargs rm -rf;
    find ./node_modules -name examples | xargs rm -rf;
    find ./node_modules -name docs | xargs rm -rf;
    find ./node_modules -name testdata | xargs rm -rf;
    mkdir -p "${CONTEXIFY_LOCATION}"
    mv ./contextify.node "${CONTEXIFY_LOCATION}/contextify.node"
    mkdir -p ${NWMATCHER_LOCATION}
    cp -r ./NW_TMP/* ${NWMATCHER_LOCATION}/
}

function rebuild_app {
    echo 'clearing node_modules'
    rm -rf ./node_modules
    echo 'cleaning npm cache'
    npm cache clean
    rm -f ./node
    cp `which node` ./
    echo 'running npm install'
    npm install --build-from-source --sqlite=${BUILD} --runtime_link=static --production --loglevel warn
    du -h -d 0 node_modules/
    echo 'running npm dedupe'
    npm dedupe
    du -h -d 0 node_modules/
    echo 'cleaning out uneeded items in node_modules'
    clean_node_modules
    du -h -d 0 node_modules/
    cd ./node_modules/mapnik
    localize_node_mapnik
    du -h -d 0 node_modules/
}

function test_app_startup {
    killall node 2>/dev/null
    killall tilemill-tile 2>/dev/null
    killall tilemill-ui 2>/dev/null
    ./index.js 2>/dev/null 1>/dev/null &
    pid=$!
    sleep 15
    kill $pid
    if [ $? != 0 ]; then
      exit_if "Unable to start app $1."
    else
      echo "$1 app started just fine"
    fi
}

function init_building {
    if [ ! -d "${THIS_BUILD_ROOT}" ]; then
        cd ${BUILD_BASE}
        git clone --depth 1 https://github.com/mapnik/mapnik-packaging.git
    fi
    cd ${THIS_BUILD_ROOT}
    START=`date +"%s"`
    this_day=$(date +"%Y-%m-%d %r")
}

function rebuild_node {
    echo 'updating node'
    if [ ! -f ${BUILD}/bin/node ] || $FORCE || $FORCE_NODE; then
        ./scripts/build_node.sh
        FORCE=true
    else
        echo "  skipping node-v${NODE_VERSION} build"
    fi
}

function rebuild_mapnik {
    echo 'updating mapnik'
    cd ${MAPNIK_SOURCE}
    git checkout $1
    git describe > mapnik.describe
    git pull
    if [ `git describe` != `cat mapnik.describe` ] || $FORCE || $FORCE_MAPNIK; then
        cd ${THIS_BUILD_ROOT}
        ./scripts/build_mapnik.sh
        FORCE=true
    else
        echo '  skipping mapnik build'
    fi
}

function rebuild_tm2 {
    echo 'updating tm2'
    # clear out old tarballs
    rm -f ${THIS_BUILD_ROOT}/tm2-*.tar.gz
    cd ${THIS_BUILD_ROOT}/tm2
    git checkout $1
    git rev-list --max-count=1 HEAD | cut -c 1-7 > tm2.describe
    git pull
    if [ `git rev-list --max-count=1 HEAD | cut -c 1-7` != `cat tm2.describe` ] || $FORCE || $FORCE_TM2; then
        git rev-list --max-count=1 HEAD | cut -c 1-7 > tm2.describe
        rebuild_app
        cd ${THIS_BUILD_ROOT}/tm2
        test_app_startup "tm2"
        # package
        cd ${THIS_BUILD_ROOT}
        echo 'CURRENT_DIRECTORY="$( cd "$( dirname "$0" )" && pwd )"
        ${CURRENT_DIRECTORY}/tm2/node ${CURRENT_DIRECTORY}/tm2/index.js
        ' > start.command
        chmod +x start.command
        filename=tm2-osx-$(date +"%Y-%m-%d")-`cat tm2/tm2.describe`${BUILD_POSTFIX}.tar.gz
        echo "creating $filename"
        tar czfH ${filename} \
          --exclude=.git* \
           start.command tm2
        #ditto -c -k --sequesterRsrc --keepParent --zlibCompressionLevel 9 tm2/ ${ZIP_ARCHIVE}
        UPLOAD="s3://tilemill/dev/${filename}"
        echo "uploading $UPLOAD"
        ./s3cmd/s3cmd --acl-public put ${filename} ${UPLOAD}
    else
        echo '  skipping tm2 build'
    fi
}

function rebuild_tilemill {
    echo 'updating tilemill'
    cd ${THIS_BUILD_ROOT}/tilemill
    git checkout $1
    git describe > tilemill.describe
    git pull
    if [ `git describe` != `cat tilemill.describe` ] || $FORCE || $FORCE_TM; then
        git describe > tilemill.describe
        rebuild_app
        cd ${THIS_BUILD_ROOT}/tilemill
        test_app_startup "tilemill"
        echo "Building TileMill Mac app..."
        cd ./platforms/osx
        make clean
        make package
        if [ $? != 0 ]; then
          exit_if "error encountered making package"
        fi
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
            exit_if "Code signing invalid. Aborting."
        fi
        echo "Creating zip archive of Mac app..."
        make zip
        dev_version=$( git describe --tags )
        filename="TileMill-${dev_version}${BUILD_POSTFIX}.zip"
        UPLOAD="s3://tilemill/dev/${filename}"
        echo "uploading $UPLOAD"
        ../../../s3cmd/s3cmd --acl-public put TileMill.zip ${UPLOAD}
        # TODO - get sparkle private key on the machine
        # https://github.com/mapbox/tilemill-builder-osx/issues/26
        #echo 'Yes' | make sparkle
    else
        echo '  skipping tilemill build'
    fi
}

function go {
    if mkdir ${LOCKFILE}; then
        echo 'no lock found, building!'
        init_building
        echo 'updating mapnik-packaging checkout'
        git pull
        source MacOSX.sh
        export JOBS=2

        # set these to ensure proper linking of all c++ libs
        # we do not set them by default to avoid linking c libs to libc++
        export LDFLAGS="${STDLIB_LDFLAGS} ${LDFLAGS}"
        
        # rebuild apps if needed
        rebuild_node
        rebuild_mapnik '2.2.x'
        rebuild_tm2 'master'
        rebuild_tilemill 'master'

        cd ${THIS_BUILD_ROOT}
        if [ ${CXX11} = true ]; then
            source MacOSX.sh
            export LDFLAGS="${STDLIB_LDFLAGS} ${LDFLAGS}"
            rebuild_node
            rebuild_mapnik 'master'
            BUILD_POSTFIX="cxx11"
            rebuild_tm2 'c++11'
            rebuild_tilemill 'c++11'
            cd ${THIS_BUILD_ROOT}
        fi

        cd ${THIS_BUILD_ROOT}
        if [ $? == 0 ]; then
            rm -rf ${LOCKFILE}
        fi
        END=`date +"%s"`
        echo "Build completed in $(( $END - $START )) seconds on $this_day"
    else
       echo 'lock found, not building!'
    fi
}
