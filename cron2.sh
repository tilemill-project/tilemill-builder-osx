#
# grab the latest build script
#
curl -s https://raw.github.com/mapbox/tilemill-builder-osx/master/build2.sh > $HOME/Desktop/build2.sh

#
# run it, saving output
#
source $HOME/Desktop/build2.sh
export FATAL=true
go 2>&1 >> /Volumes/Flex/build2.log

