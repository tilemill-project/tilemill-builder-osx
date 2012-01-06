#!/bin/bash

#
# Establish a strict path so we don't pull in extraneous stuff.
#
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/usr/X11/bin

clear
START=`date +"%s"`
JOBS=`sysctl -n hw.ncpu`
ROOT=/Volumes/Flex

#
# Check for things we know we'll need ahead of time.
#
NPM=`which npm`
if [ -z $NPM ]; then
  echo "Unable to find npm in the path."
  exit 1
fi

#
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
find $ROOT -mtime +7 -maxdepth 1 -name build-\* -type d 2>/dev/null | xargs rm -rf
date=$( date +"%Y-%m-%d-%H%M%S" )
JAIL="$ROOT/build-$date"
echo "Going to work in $JAIL"
echo "Developer Tools:"
xcodebuild -version
echo "Running with $JOBS parallel jobs."
rm -rf $JAIL 2>/dev/null
mkdir -p $JAIL/bin
cd $JAIL

# default to Clang
export CC=clang
export CXX=clang++

#
# Build & fatten Node.js.
#

NODE_VERSION=v0.4.12

mkdir node
cd node

echo "Building Node..."
curl -# http://nodejs.org/dist/node-$NODE_VERSION.tar.gz > node-$NODE_VERSION.tar.gz
tar xf node-$NODE_VERSION.tar.gz
cd node-$NODE_VERSION
# build i386
./configure --prefix=$JAIL --without-snapshot --jobs=$JOBS --blddir=node-32 --dest-cpu=ia32
# install headers
make -j$JOBS install
# build x86_64
./configure --prefix=$JAIL --without-snapshot --jobs=$JOBS --blddir=node-64 --dest-cpu=x64
make
lipo -create node-32/default/node node-64/default/node -output node

cp node $JAIL/bin
chmod +x $JAIL/bin/node

export PATH=$JAIL/bin:$PATH

cd $JAIL

fat_node=`which node`
if [ `$fat_node --version` != $NODE_VERSION ] || [ -z "`file $fat_node | grep i386`" ] || [ -z "`file $fat_node | grep x86_64`" ]; then
  echo "Unable to build dual-arch node."
  exit 1
fi

echo "Dual-arch Node at $JAIL/bin/node"

#
# Check for required global node modules and no others.
#
echo "Checking for required global modules..."

SEARCH_PATHS="/usr/local/lib/node_modules /usr/local/lib/node `node -e "require.paths" | sed -e 's/^\[//' -e 's/\]$//' -e 's/,//'`"
MODULES="jshint npm wafadmin"
proper_module_count=0
for module in $MODULES; do
  found_match="`find $SEARCH_PATHS -type d -name $module 2>/dev/null | sed -n '1p'`"
  if [ -z $found_match ]; then
    echo "Unable to find globally-installed '$module'. Try \`sudo npm install -g $module\`"
    exit 1
  fi
  let proper_module_count++
done

actual_module_count=0
for search_path in $SEARCH_PATHS; do
  for found_module in `find $search_path -type d -maxdepth 1 2>/dev/null | sed -e '1d'`; do
    echo "Found $found_module in $search_path"
    let actual_module_count++
  done
done

if [ $actual_module_count -gt $proper_module_count ]; then
  echo "Found $actual_module_count global modules when we should only have $proper_module_count modules."
  exit 1
fi

#
# Setup Mapnik SDK.
#
echo "Building Mapnik SDK..."

cd $JAIL
rm -rf mapnik 2>/dev/null
git clone --depth=1 https://github.com/mapnik/mapnik.git -b macbinary-tilemill mapnik
cd mapnik
mkdir osx
cd osx
echo "Fetching remote sources..."
curl -# -o sources.tar.bz2 http://dbsgeo.com/tmp/mapnik-static-sdk-2.1.0-dev_r2.tar.bz2
tar xf sources.tar.bz2
cd ..
./configure JOBS=$JOBS
make
make install

export MAPNIK_ROOT=`pwd`/osx/sources
export PATH=$MAPNIK_ROOT/usr/local/bin:$PATH

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

export CORE_CXXFLAGS="-O3 -arch x86_64 -arch i386 -mmacosx-version-min=10.6 -isysroot /Developer/SDKs/MacOSX10.6.sdk"
export CORE_LINKFLAGS="-arch x86_64 -arch i386 -mmacosx-version-min=10.6 -isysroot /Developer/SDKs/MacOSX10.6.sdk"
export CXXFLAGS="$CORE_LINKFLAGS -I$MAPNIK_ROOT/include -I$MAPNIK_ROOT/usr/local/include $CORE_CXXFLAGS"
export LINKFLAGS="$CORE_LINKFLAGS -L$MAPNIK_ROOT/lib -L$MAPNIK_ROOT/usr/local/lib -Wl,-search_paths_first $CORE_LINKFLAGS"
export JOBS=$JOBS

npm install . --verbose

#
# Check various modules are linked against system libraries and are dual-arch.
#
echo "Checking module linking & architecture..."

for module in mbtiles/node_modules/zlib/lib/zlib_bindings.node tilelive-mapnik/node_modules/eio/build/default/eio.node millstone/node_modules/srs/lib/_srs.node millstone/node_modules/zipfile/lib/_zipfile.node; do
  echo "Checking node_modules/$module for consistency..."
  if [ -n "`otool -L node_modules/$module | grep version | sed -e 's/^[^\/]*//' | grep -v ^\/usr/lib`" ]; then
    echo "Module $module is linked against non-system libraries."
    exit 1
  fi
  if [ -z "`file node_modules/$module | grep i386`" ] || [ -z "`file node_modules/$module | grep x86_64`" ]; then
    echo "Module $module is not dual-arch."
    exit 1
  fi
done

cd $JAIL


#
# Make various fixes to the Mapnik module so that plugins work.
#

echo "Fixing up Mapnik module..."

cd $JAIL/tilemill/node_modules/mapnik

export MAPNIK_INPUT_PLUGINS="path.join(__dirname, 'input')"
export MAPNIK_FONTS="path.join(__dirname, 'fonts')"

./configure
node-waf -v build
cp $MAPNIK_ROOT/usr/local/lib/libmapnik.dylib lib/libmapnik.dylib
install_name_tool -id libmapnik.dylib lib/libmapnik.dylib
install_name_tool -change /usr/local/lib/libmapnik.dylib @loader_path/libmapnik.dylib lib/_mapnik.node

mkdir -p lib/fonts
rm lib/fonts/* 2>/dev/null
cp -R $MAPNIK_ROOT/usr/local/lib/mapnik/fonts lib/

mkdir -p lib/input
rm lib/input/*.input 2>/dev/null
cp $MAPNIK_ROOT/usr/local/lib/mapnik/input/*.input lib/input/
for lib in `ls lib/input/*input`; do
  install_name_tool -change /usr/local/lib/libmapnik.dylib @loader_path/../libmapnik.dylib $lib;
done

#
# Run Mapnik tests.
#
echo "Running Mapnik module tests..."

mapnik_failures=`make test 2>&1 | grep failed | grep -v '+init=epsg:'`
if [ -n "$mapnik_failures" ]; then
  echo "Mapnik test failures:"
  echo $mapnik_failures
  exit 1
fi

#
# Check Mapnik module.
#
echo "Checking Mapnik module linking & architecture..."

cd $JAIL/tilemill

rm node_modules/bones/node_modules/jquery/node_modules/htmlparser/libxmljs.node 2>/dev/null
rm node_modules/mapnik/build/default/_mapnik.node 2>/dev/null

for i in `find . -name '*.node'`; do
  if [ -n "`otool -L $i | grep version | sed -e 's/^[^\/@]*//' | grep -v ^\/usr/lib | grep -v '@loader_path/libmapnik.dylib'`" ] || [ -n "`otool -L $i | grep local`" ]; then
    echo "Improper linking for $i"
    exit 1
  fi
done

# 
# Test that the app works.
# 
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
appcast="http://mapbox.com/tilemill/platforms/osx/appcast-dev.xml"
defaults write $plist SUFeedURL $appcast

echo "Ensuring proper permissions on Info.plist..."
chmod 644 $plist.plist

echo "Creating zip archive of Mac app..."
make zip
dev_version=$( git describe --tags | sed -e 's/^v//' | sed -e 's/-/./' | sed -e 's/-.*//' )
filename="TileMill-$dev_version.zip"
mv TileMill.zip $JAIL/$filename
echo "Created $filename of `stat -f %z $JAIL/$filename` bytes in size."

rm $ROOT/TileMill-latest.zip
ln -s $JAIL/$filename $ROOT/TileMill-latest.zip
rm $ROOT/build-latest
ln -s $JAIL $ROOT/build-latest

#
# Close it out.
#
END=`date +"%s"`
echo "Build complete in $(( $END - $START )) seconds."
