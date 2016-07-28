#!/bin/bash

# Copyright 2014-2015 Holger Levsen <holger@layer-acht.org>
#         © 2015 Reiner Herrmann <reiner@reiner-h.de>
#           2016 Alexander Couzens <lynxis@fe80.eu>
# released under the GPLv=2

OPENWRT_GIT_REPO=https://git.lede-project.org/source.git
OPENWRT_GIT_BRANCH=master
DEBUG=true
. /srv/jenkins/bin/common-functions.sh
common_init "$@"

# common code defining db access
. /srv/jenkins/bin/reproducible_common.sh
. /srv/jenkins/bin/reproducible_openwrt_common.sh
set -e

#
# main
#
TMPBUILDDIR=$(mktemp --tmpdir=/srv/workspace/chroots/ -d -t rbuild-lede-build-XXXXXXXX)  # used to build on tmpfs
TMPDIR=$(mktemp --tmpdir=/srv/reproducible-results -d -t rbuild-lede-results-XXXXXXXX)  # accessable in schroots, used to compare results
BANNER_HTML=$(mktemp --tmpdir=$TMPDIR)
DATE=$(date -u +'%Y-%m-%d')
START=$(date +'%s')
trap cleanup_tmpdirs INT TERM EXIT

cd $TMPBUILDDIR
echo "============================================================================="
echo "$(date -u) - Cloning LEDE git repository."
echo "============================================================================="
git clone --depth 1 -b $OPENWRT_GIT_BRANCH $OPENWRT_GIT_REPO lede
cd lede
OPENWRT="$(git log -1)"
OPENWRT_VERSION=$(git describe --always)
echo "This is lede $OPENWRT_VERSION."
echo
git log -1

# External feeds disabled for now as they break building (especially with CONFIG_ALL=y).
#echo "============================================================================="
#echo "$(date -u) - Updating package feeds."
#echo "============================================================================="
#./scripts/feeds update -a
#./scripts/feeds install -a

create_results_dirs lede

build_two_times lede ar71xx_generic_ARCHERC7 "CONFIG_TARGET_ar71xx_generic=y\nCONFIG_TARGET_ar71xx_generic_ARCHERC7=y\n"

# for now we only build one architecture until it's at most reproducible
#build_two_times x86_64 "CONFIG_TARGET_x86=y\nCONFIG_TARGET_x86_64=y\n"
#build_two_times ramips_rt288x_RTN15 "CONFIG_TARGET_ramips=y\nCONFIG_TARGET_ramips_rt288x=y\nCONFIG_TARGET_ramips_rt288x_RTN15=y\n"

#
# create html about toolchain used
#
echo "============================================================================="
echo "$(date -u) - Creating Documentation HTML"
echo "============================================================================="
TOOLCHAIN_HTML=$(mktemp --tmpdir=$TMPDIR)
echo "<table><tr><th>Target toolchains built</th></tr>" > $TOOLCHAIN_HTML
for i in $(ls -1d staging_dir/toolchain*|cut -d "-" -f2-|xargs echo) ; do
	echo " <tr><td><code>$i</code></td></tr>" >> $TOOLCHAIN_HTML
done
echo "</table>" >> $TOOLCHAIN_HTML
echo "<table><tr><th>Contents of <code>build_dir/host/</code></th></tr>" >> $TOOLCHAIN_HTML
for i in $(ls -1 build_dir/host/) ; do
	echo " <tr><td>$i</td></tr>" >> $TOOLCHAIN_HTML
done
echo "</table>" >> $TOOLCHAIN_HTML
echo "<table><tr><th>Downloaded software</th></tr>" >> $TOOLCHAIN_HTML
for i in $(ls -1 dl/) ; do
	echo " <tr><td>$i</td></tr>" >> $TOOLCHAIN_HTML
done
echo "</table>" >> $TOOLCHAIN_HTML
echo "<table><tr><th>Debian $(cat /etc/debian_version) package on $(dpkg --print-architecture)</th><th>installed version</th></tr>" >> $TOOLCHAIN_HTML
for i in gcc binutils bzip2 flex python perl make findutils grep diffutils unzip gawk util-linux zlib1g-dev libc6-dev git subversion ; do
	echo " <tr><td>$i</td><td>" >> $TOOLCHAIN_HTML
	dpkg -s $i|grep '^Version'|cut -d " " -f2 >> $TOOLCHAIN_HTML
	echo " </td></tr>" >> $TOOLCHAIN_HTML
done
echo "</table>" >> $TOOLCHAIN_HTML

# clean up builddir to save space on tmpfs
rm -rf $TMPBUILDDIR/lede

# run diffoscope on the results
# (this needs refactoring rather badly)
TIMEOUT="30m"
DIFFOSCOPE="$(schroot --directory /tmp -c source:jenkins-reproducible-${DBDSUITE}-diffoscope diffoscope -- --version 2>&1)"
echo "============================================================================="
echo "$(date -u) - Running $DIFFOSCOPE on LEDE images and packages."
echo "============================================================================="
DBD_HTML=$(mktemp --tmpdir=$TMPDIR)
DBD_GOOD_PKGS_HTML=$(mktemp --tmpdir=$TMPDIR)
DBD_BAD_PKGS_HTML=$(mktemp --tmpdir=$TMPDIR)
# run diffoscope on the images
GOOD_IMAGES=0
ALL_IMAGES=0
SIZE=""
cd $TMPDIR/b1/targets
tree .

# iterate over all images (merge b1 and b2 images into one list)
# call diffoscope on the images
for target in * ; do
	cd $target
	for subtarget in * ; do
		cd $subtarget

		# search images in both paths to find non-existing ones
		IMGS1=$(find * -type f -name "*.bin" -o -name "*.squashfs" | sort -u )
		pushd $TMPDIR/b2/targets/$target/$subtarget
		IMGS2=$(find * -type f -name "*.bin" -o -name "*.squashfs" | sort -u )
		popd

		echo "       <table><tr><th>Images for <code>$target/$subtarget</code></th></tr>" >> $DBD_HTML
		for image in $(printf "$IMGS1\n$IMGS2" | sort -u ) ; do
			let ALL_IMAGES+=1
			if [ ! -f $TMPDIR/b1/targets/$target/$subtarget/$image -o ! -f $TMPDIR/b2/targets/$target/$subtarget/$image ] ; then
				echo "         <tr><td><img src=\"/userContent/static/weather-storm.png\" alt=\"ftbfs icon\" /> $image (${SIZE}) failed to build.</td></tr>" >> $DBD_HTML
				rm -f $BASE/lede/dbd/targets/$target/$subtarget/$image.html # cleanup from previous (unreproducible) tests - if needed
				continue
			fi
			call_diffoscope $target/$subtarget $image
			get_filesize $image
			if [ -f $TMPDIR/$target/$subtarget/$image.html ] ; then
				mkdir -p $BASE/lede/dbd/targets/$target/$subtarget
				mv $TMPDIR/targets/$target/$subtarget/$image.html $BASE/lede/dbd/targets/$target/$subtarget/$image.html
				echo "         <tr><td><a href=\"dbd/targets/$target/$subtarget/$image.html\"><img src=\"/userContent/static/weather-showers-scattered.png\" alt=\"unreproducible icon\" /> $image</a> (${SIZE}) is unreproducible.</td></tr>" >> $DBD_HTML
			else
				SHASUM=$(sha256sum $image|cut -d " " -f1)
				echo "         <tr><td><img src=\"/userContent/static/weather-clear.png\" alt=\"reproducible icon\" /> $image ($SHASUM, $SIZE) is reproducible.</td></tr>" >> $DBD_HTML
				let GOOD_IMAGES+=1
				rm -f $BASE/lede/dbd/targets/$target/$subtarget/$image.html # cleanup from previous (unreproducible) tests - if needed
			fi
		done
		cd ..
		echo "       </table>" >> $DBD_HTML
	done
	cd ..
done
GOOD_PERCENT_IMAGES=$(echo "scale=1 ; ($GOOD_IMAGES*100/$ALL_IMAGES)" | bc)
# run diffoscope on the packages
GOOD_PACKAGES=0
ALL_PACKAGES=0
cd $TMPDIR/b1
for i in * ; do
	cd $i

	# search packages in both paths to find non-existing ones
	PKGS1=$(find * -type f -name "*.ipk" | sort -u )
	pushd $TMPDIR/b2/$i
	PKGS2=$(find * -type f -name "*.ipk" | sort -u )
	popd

	for j in $(printf "$PKGS1\n$PKGS2" | sort -u ) ; do
		let ALL_PACKAGES+=1
		if [ ! -f $TMPDIR/b1/$i/$j -o ! -f $TMPDIR/b2/$i/$j ] ; then
			echo "         <tr><td><img src=\"/userContent/static/weather-storm.png\" alt=\"ftbfs icon\" /> $j (${SIZE}) failed to build.</td></tr>" >> $DBD_BAD_PKGS_HTML
			rm -f $BASE/lede/dbd/$i/$j.html # cleanup from previous (unreproducible) tests - if needed
			continue
		fi
		call_diffoscope $i $j
		get_filesize $j
		if [ -f $TMPDIR/$i/$j.html ] ; then
			mkdir -p $BASE/lede/dbd/$i/$(dirname $j)
			mv $TMPDIR/$i/$j.html $BASE/lede/dbd/$i/$j.html
			echo "         <tr><td><a href=\"dbd/$i/$j.html\"><img src=\"/userContent/static/weather-showers-scattered.png\" alt=\"unreproducible icon\" /> $j</a> ($SIZE) is unreproducible.</td></tr>" >> $DBD_BAD_PKGS_HTML
		else
			SHASUM=$(sha256sum $j|cut -d " " -f1)
			echo "         <tr><td><img src=\"/userContent/static/weather-clear.png\" alt=\"reproducible icon\" /> $j ($SHASUM, $SIZE) is reproducible.</td></tr>" >> $DBD_GOOD_PKGS_HTML
			let GOOD_PACKAGES+=1
			rm -f $BASE/lede/dbd/$i/$j.html # cleanup from previous (unreproducible) tests - if needed
		fi
	done
	cd ..
done
echo "       <table><tr><th>Unreproducible and otherwise broken packages</th></tr>" >> $DBD_HTML
cat $DBD_BAD_PKGS_HTML >> $DBD_HTML
echo "       </table>" >> $DBD_HTML
echo "       <table><tr><th>Reproducible packages</th></tr>" >> $DBD_HTML
cat $DBD_GOOD_PKGS_HTML >> $DBD_HTML
echo "       </table>" >> $DBD_HTML
GOOD_PERCENT_PACKAGES=$(echo "scale=1 ; ($GOOD_PACKAGES*100/$ALL_PACKAGES)" | bc)
# are we there yet?
if [ "$GOOD_PERCENT_IMAGES" = "100.0" ] || [ "$GOOD_PERCENT_PACKAGES" = "100.0" ]; then
	MAGIC_SIGN="!"
else
	MAGIC_SIGN="?"
fi

#
#  finally create the webpage
#
cd $TMPDIR ; mkdir lede
PAGE=lede/lede.html
cat > $PAGE <<- EOF
<!DOCTYPE html>
<html lang="en-US">
  <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width">
    <title>Reproducible LEDE ?</title>
    <link rel='stylesheet' id='kamikaze-style-css'  href='cascade.css?ver=4.0' type='text/css' media='all'>
  </head>
  <body>
    <div id="header">
        <p><center>
        <code>
EOF
cat $BANNER_HTML >> $PAGE
write_page "       </code></center></p>"
write_page "     </div><div id=\"main-content\">"
write_page "       <h1>LEDE - <em>reproducible</em> wireless freedom$MAGIC_SIGN</h1>"
write_page_intro LEDE
write_page "       <p>$GOOD_IMAGES ($GOOD_PERCENT_IMAGES%) out of $ALL_IMAGES built images and $GOOD_PACKAGES ($GOOD_PERCENT_PACKAGES%) out of $ALL_PACKAGES built packages were reproducible in our test setup."
write_page "        These tests were last run on $DATE for version ${OPENWRT_VERSION} using ${DIFFOSCOPE}.</p>"
write_variation_table LEDE
cat $DBD_HTML >> $PAGE
write_page "     <table><tr><th>git commit built</th></tr><tr><td><code>"
echo -n "$OPENWRT" >> $PAGE
write_page "     </code></td></tr></table>"
cat $TOOLCHAIN_HTML >> $PAGE
write_page "    </div>"
write_page_footer LEDE
publish_page
rm -f $DBD_HTML $DBD_GOOD_PKGS_HTML $DBD_BAD_PKGS_HTML $TOOLCHAIN_HTML $BANNER_HTML

# the end
calculate_build_duration
print_out_duration
irc_message reproducible-builds "$REPRODUCIBLE_URL/lede/ has been updated. ($GOOD_PERCENT_IMAGES% images and $GOOD_PERCENT_PACKAGES% packages reproducible)"
echo "============================================================================="

# remove everything, we don't need it anymore...
cleanup_tmpdirs
trap - INT TERM EXIT
