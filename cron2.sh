#
# grab the latest build script
#

# cd ~/Desktop && git clone https://github.com/mapbox/tilemill-builder-osx.git
cd $HOME/Desktop/tilemill-builder-osx
git rev-list --max-count=1 HEAD | cut -c 1-7 > build.describe
git pull

#
# run it, saving output
#
echo 'sourcing build env'
source ./build2.sh
# if the build script changed, force new build
if [[ `git rev-list --max-count=1 HEAD | cut -c 1-7` != `cat build.describe` ]]; then
    echo 'forcing build because build script changed'
    export FORCE=true
fi
source ./config.sh
go 2>&1 >> /Volumes/Flex/build2.log

