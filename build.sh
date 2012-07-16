#!/bin/bash

#
# Establish a strict path so we don't pull in extraneous stuff.
#
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/usr/X11/bin

START=`date +"%s"`
DATE_NOW=$( date +"%Y-%m-%d-%H%M%S" )
ROOT=/Volumes/Flex

JAIL="$ROOT/build-$DATE_NOW"

LOCAL_MAPNIK_SDK="$ROOT/mapnik-packaging/osx/build"
# todo - try using icu-config --version to dynamically fetch
ICU_VERSION="49.1"
NODE_VERSION="v0.6.20"
export PATH=$JAIL/bin:$PATH
export XCODE_PREFIX=$( xcode-select -print-path )
# default to Clang
export CC=clang
export CXX=clang++
export MAPNIK_ROOT=${JAIL}/mapnik/mapnik-osx-sdk
export PATH=$MAPNIK_ROOT/usr/local/bin:$PATH
export MAPNIK_INPUT_PLUGINS="path.join(__dirname, 'mapnik/input')"
export MAPNIK_FONTS="path.join(__dirname, 'mapnik/fonts')"
export LIBMAPNIK_PATH=${MAPNIK_ROOT}/usr/local/lib

if [[ $XCODE_PREFIX == "/Developer" ]]; then
   SDK_PATH="${XCODE_PREFIX}/SDKs/MacOSX10.6.sdk" ## Xcode 4.2
   export PATH=/Developer/usr/bin:$PATH
else
   SDK_PATH="${XCODE_PREFIX}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.6.sdk" ## >= 4.3.1 from MAC
fi

export CORE_CXXFLAGS="-O3 -arch x86_64 -mmacosx-version-min=10.6 -isysroot $SDK_PATH"
export CORE_LINKFLAGS="-arch x86_64 -mmacosx-version-min=10.6 -isysroot $SDK_PATH"
export CXXFLAGS="$CORE_LINKFLAGS -I$MAPNIK_ROOT/include -I$MAPNIK_ROOT/usr/local/include $CORE_CXXFLAGS"
export LINKFLAGS="$CORE_LINKFLAGS -L$MAPNIK_ROOT/lib -L$MAPNIK_ROOT/usr/local/lib -Wl,-S -Wl,-search_paths_first $CORE_LINKFLAGS"

export JOBS=`sysctl -n hw.ncpu`
if [[ $JOBS > 4 ]]; then
    export JOBS=$(expr $JOBS - 2)
fi



# begin
clear

# clean up buld-active
rm $ROOT/build-active 2>/dev/null


# Ensure there is no globally-installed mapnik
#
echo "Checking for globally-installed Mapnik..."
global_mapnik=`which mapnik-config`
if [ -n "$global_mapnik" ]; then
  echo "Please remove globally-installed mapnik detected via config at $global_mapnik"
  exit 1
fi

#
# Set up shop someplace isolated & clean house.
#
echo "Cleaning up old builds..."
find $ROOT -mtime +7 -maxdepth 1 -name build-\* -type d 2>/dev/null | xargs rm -rf
echo "Going to work in $JAIL"
ln -s $JAIL $ROOT/build-active
echo "Developer Tools:"
xcodebuild -version
echo "Developer Path:"
echo $XCODE_PREFIX
echo "SDK Path:"
echo $SDK_PATH
echo "Running with $JOBS parallel jobs."
rm -rf $JAIL 2>/dev/null
mkdir -p $JAIL/bin
cd $JAIL

#
# Build Node.js.
#

mkdir node
cd node

echo "Building Node..."
curl -# http://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION.tar.gz > node-$NODE_VERSION.tar.gz
tar xf node-$NODE_VERSION.tar.gz
cd node-$NODE_VERSION
./configure --prefix=$JAIL
make -j$JOBS install


cd $JAIL

echo "Node now built and installed to $JAIL/bin/node"

#
# Ensure npm is now also installed
#
NPM=`which npm`
if [ -z $NPM ]; then
  echo "Unable to find npm in the path."
  exit 1
fi

#
# Clear npm cache to avoid potential build failures during development
# https://github.com/mapbox/tilemill-builder-osx/issues/15
#

echo "Cleaning npm cache…"
npm cache clean


#
# Check for required global node modules and no others.
#
echo "Checking for required global modules..."

#SEARCH_PATHS="/usr/local/lib/node_modules /usr/local/lib/node"
#MODULES="jshint npm wafadmin"
#proper_module_count=0
#for module in $MODULES; do
#  found_match="`find $SEARCH_PATHS -type d -name $module 2>/dev/null | sed -n '1p'`"
#  if [ -z $found_match ]; then
#    echo "Unable to find globally-installed '$module'. Try \`sudo npm install -g $module\`"
#    exit 1
#  fi
#  let proper_module_count++
#done

#actual_module_count=0
#for search_path in $SEARCH_PATHS; do
#  for found_module in `find $search_path -type d -maxdepth 1 2>/dev/null | sed -e '1d'`; do
#    echo "Found $found_module in $search_path"
#    let actual_module_count++
#  done
#done

#if [ $actual_module_count -gt $proper_module_count ]; then
#  echo "Found $actual_module_count global modules when we should only have $proper_module_count modules."
#  exit 1
#fi

#
# Setup Mapnik SDK.
#
echo "Building Mapnik SDK..."

# limit jobs more aggressively for mapnik, to avoid low mem conditions
JOBS=`sysctl -n hw.ncpu`
if [[ $JOBS > 4 ]]; then
    JOBS=$(expr $JOBS - 4)
fi

cd $JAIL
rm -rf mapnik 2>/dev/null
git clone --depth=1 https://github.com/mapnik/mapnik.git -b master mapnik
cd mapnik

echo "CUSTOM_CXXFLAGS = \"-arch x86_64 -g -mmacosx-version-min=10.6 -isysroot $SDK_PATH -Imapnik-osx-sdk/include \"" > config.py
echo "CUSTOM_LDFLAGS = \"-Wl,-S -Wl,-search_paths_first -arch x86_64 -mmacosx-version-min=10.6 -isysroot $SDK_PATH -Lmapnik-osx-sdk/lib \"" >> config.py
echo "CXX = \"$CXX\"" >> config.py
echo "CC = \"$CC\"" >> config.py
echo "JOBS = \"$JOBS\"" >> config.py
cat << 'EOF' >> config.py
RUNTIME_LINK = "static"
INPUT_PLUGINS = "csv,gdal,ogr,postgis,shape,sqlite"
WARNING_CXXFLAGS = "-Wno-unused-function"
DESTDIR = "./mapnik-osx-sdk/"
PATH = "./mapnik-osx-sdk/bin/"
PATH_REPLACE = "/Users/dane/projects/mapnik-packaging/osx/build:./mapnik-osx-sdk"
BOOST_INCLUDES = "./mapnik-osx-sdk/include"
BOOST_LIBS = "./mapnik-osx-sdk/lib"
FREETYPE_CONFIG = "./mapnik-osx-sdk/bin/freetype-config"
ICU_INCLUDES = "./mapnik-osx-sdk/include"
ICU_LIBS = './mapnik-osx-sdk/lib'
PNG_INCLUDES = "./mapnik-osx-sdk/include"
PNG_LIBS = "./mapnik-osx-sdk/lib"
JPEG_INCLUDES = "./mapnik-osx-sdk/include"
JPEG_LIBS = "./mapnik-osx-sdk/lib"
TIFF_INCLUDES = "./mapnik-osx-sdk/include"
TIFF_LIBS = "./mapnik-osx-sdk/lib"
PROJ_INCLUDES = "./mapnik-osx-sdk/include"
PROJ_LIBS = "./mapnik-osx-sdk/lib"
PKG_CONFIG_PATH = "./mapnik-osx-sdk/lib/pkgconfig"
CAIRO = True
CAIRO_INCLUDES = "./mapnik-osx-sdk/include"
CAIRO_LIBS = "./mapnik-osx-sdk/lib"
SQLITE_INCLUDES = "./mapnik-osx-sdk/include"
SQLITE_LIBS = "./mapnik-osx-sdk/lib"
BINDINGS = "none"
EOF

if [ -d "${LOCAL_MAPNIK_SDK}" ]; then
    echo "Using local mapnik sdk..."
    ln -s "${LOCAL_MAPNIK_SDK}" `pwd`/mapnik-osx-sdk
else
    echo "Fetching remote mapnik sdk..."
    wget http://mapnik.s3.amazonaws.com/mapnik-osx-sdk.tar.bz2
    tar xf mapnik-osx-sdk.tar.bz2
fi

./configure
make install

# ensure plugins are present
if [[ ! -f "$MAPNIK_ROOT/usr/local/lib/mapnik/input/csv.input" ]]; then
  echo "Missing Mapnik CSV plugin!"
  exit 1
fi

if [[ ! -f "$MAPNIK_ROOT/usr/local/lib/mapnik/input/gdal.input" ]]; then
  echo "Missing Mapnik GDAL plugin!"
  exit 1
fi

if [[ ! -f "$MAPNIK_ROOT/usr/local/lib/mapnik/input/postgis.input" ]]; then
  echo "Missing Mapnik POSTGIS plugin!"
  exit 1
fi

if [[ ! -f "$MAPNIK_ROOT/usr/local/lib/mapnik/input/shape.input" ]]; then
  echo "Missing Mapnik Shapefile plugin!"
  exit 1
fi

if [[ ! -f "$MAPNIK_ROOT/usr/local/lib/mapnik/input/ogr.input" ]]; then
  echo "Missing Mapnik OGR plugin!"
  exit 1
fi

if [[ ! -f "$MAPNIK_ROOT/usr/local/lib/mapnik/input/sqlite.input" ]]; then
  echo "Missing Mapnik SQLite plugin!"
  exit 1
fi


cd $JAIL

if [ -z "`which mapnik-config | grep $MAPNIK_ROOT`" ]; then
  echo "Unable to setup Mapnik SDK."
  exit 1
fi

#
# Build TileMill.
#
echo "Building TileMill..."

cd $JAIL
rm -rf tilemill 2>/dev/null
git clone https://github.com/mapbox/tilemill.git tilemill
cd tilemill

npm install
rm -rf node_modules/sqlite3
npm install

#
# Check various modules are linked against system libraries and are dual-arch.
#
#echo "Checking module linking & architecture..."
#
#for module in tilelive-mapnik/node_modules/eio/lib/eio.node millstone/node_modules/srs/lib/_srs.node millstone/node_modules/zipfile/lib/_zipfile.node; do
#  echo "Checking node_modules/$module for consistency..."
#  if [ -n "`otool -L node_modules/$module | grep version | sed -e 's/^[^\/]*//' | grep -v ^\/usr/lib`" ]; then
#    echo "Module $module is linked against non-system libraries."
#    exit 1
#  fi
#  if [ -z "`file node_modules/$module | grep i386`" ] || [ -z "`file node_modules/$module | grep x86_64`" ]; then
#    echo "Module $module is not dual-arch."
#    exit 1
#  fi
#done

cd $JAIL


#
# Make node-mapnik portable
#

echo "Fixing up Mapnik module..."

cd $JAIL/tilemill/node_modules/mapnik

./configure

# copy the lib into place
cp ${LIBMAPNIK_PATH}/libmapnik.dylib lib/libmapnik.dylib
# copy plugins and fonts
cp -r ${LIBMAPNIK_PATH}/mapnik lib/

# copy data
# TODO - this will not be present with a source build
#cp -r ${LIBMAPNIK_PATH}/../share lib/

# fixup install names to be portable
install_name_tool -id libmapnik.dylib lib/libmapnik.dylib
# TODO - abstract out this /usr/local/lib path
install_name_tool -change /usr/local/lib/libmapnik.dylib @loader_path/libmapnik.dylib lib/_mapnik.node

for lib in `ls lib/mapnik/input/*input`; do
  install_name_tool -change /usr/local/lib/libmapnik.dylib @loader_path/../../libmapnik.dylib $lib;
done

mkdir -p lib/mapnik/share

echo "
module.exports.env = {
    'ICU_DATA': path.join(__dirname, 'mapnik/share/icu'),
    'GDAL_DATA': path.join(__dirname, 'mapnik/share/gdal'),
    'PROJ_LIB': path.join(__dirname, 'mapnik/share/proj')
};
" >> lib/mapnik_settings.js
#
# Run Mapnik tests.
#
echo "Running Mapnik module tests..."

#mapnik_failures=`make test 2>&1 | grep failed | grep -v '+init=epsg:'`
#if [ -n "$mapnik_failures" ]; then
#  echo "Mapnik test failures:"
#  echo $mapnik_failures
#  exit 1
#fi

#
# Check Mapnik module.
#
echo "Checking Mapnik module linking & architecture..."

cd $JAIL/tilemill

# clean up some unneeded MB's
rm -rf ./node_modules/mapnik/build/ 2>/dev/null

for i in `find . -name '*.node'`; do
  if [ -n "`otool -L $i | grep version | sed -e 's/^[^\/@]*//' | grep -v ^\/usr/lib | grep -v '@loader_path/libmapnik.dylib'`" ] || [ -n "`otool -L $i | grep local`" ]; then
    echo "Improper linking for $i"
    #exit 1
  fi
done

#
# Package some data for proj,gdal, and mapnik (icu)
#

# 
# Test that the app works.
echo "packaging data..."

# package data for mapnik inside node-mapnik folder
# https://github.com/mapbox/tilemill/issues/1390
cp -r ${LOCAL_MAPNIK_SDK}/share/proj $JAIL/tilemill/node_modules/mapnik/lib/mapnik/share/
cp -r ${LOCAL_MAPNIK_SDK}/share/gdal $JAIL/tilemill/node_modules/mapnik/lib/mapnik/share/
mkdir -p $JAIL/tilemill/node_modules/mapnik/lib/mapnik/share/icu
cp ${LOCAL_MAPNIK_SDK}/share/icu/$ICU_VERSION/*dat $JAIL/tilemill/node_modules/mapnik/lib/mapnik/share/icu

echo "Testing TileMill startup..."

cd $JAIL/tilemill
killall node 2>/dev/null
./index.js 2>/dev/null 1>/dev/null &
pid=$!
sleep 10
kill $pid
if [ $? != 0 ]; then
  echo "Unable to start TileMill."
  exit 1
fi

#
# Build the Mac app.
#
echo "Building TileMill Mac app..."

# unset compiler; use Xcode-specified
export CC=
export CXX=

cd $JAIL/tilemill/platforms/osx
make clean
make package
make package # second time should complete

if [ $? != 0 ]; then
  echo "Error making Xcode project (\`make package\`). Aborting."
  exit 1
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

echo "Code signing with Developer ID"
security unlock-keychain -p "$( cat $HOME/.keychain )"
codesign -s "Developer ID Application: Development Seed" "$( pwd )/build/Release/TileMill.app"
security lock-keychain
spctl -v --assess "$( pwd )/build/Release/TileMill.app" || echo "Gatekeeper signing not valid."

echo "Creating zip archive of Mac app..."
make zip
dev_version=$( git describe --tags | sed -e 's/^v//' | sed -e 's/-/./' | sed -e 's/-.*//' )
filename="TileMill-$dev_version.zip"
mv TileMill.zip $JAIL/$filename
echo "Created $filename of `stat -f %z $JAIL/$filename` bytes in size."

rm $ROOT/TileMill-latest.zip 2>/dev/null
ln -s $JAIL/$filename $ROOT/TileMill-latest.zip
rm $ROOT/build-latest 2>/dev/null
ln -s $JAIL $ROOT/build-latest
rm $ROOT/build-active 2>/dev/null

#
# Close it out.
#
END=`date +"%s"`
echo "Build complete in $(( $END - $START )) seconds."
