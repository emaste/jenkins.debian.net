#!/bin/bash

# Copyright 2015 Holger Levsen <holger@layer-acht.org>
# released under the GPLv=2

DEBUG=false
. /srv/jenkins/bin/common-functions.sh
common_init "$@"

# common code
. /srv/jenkins/bin/reproducible_common.sh

set -e

cleanup_all() {
	cd
	# delete session if it still exists
	if [ "$MODE" != "master" ] ; then
		schroot --end-session -c archlinux-$SRCPACKAGE-$(basename $TMPDIR) > /dev/null 2>&1 || true
	fi
	# delete makepkg build dir
	if [ ! -z $SRCPACKAGE ] && [ -d /tmp/$SRCPACKAGE-$(basename $TMPDIR) ] ; then
		rm -r /tmp/$SRCPACKAGE-$(basename $TMPDIR)
	fi
	# delete main work dir (only on master)
	if [ "$MODE" = "master" ] ; then
		rm $TMPDIR -r
		echo "$(date -u) - $TMPDIR deleted."
	fi
	rm -f $DUMMY > /dev/null || true
}

handle_remote_error() {
	MESSAGE="${BUILD_URL}console got remote error $1"
	echo "$(date -u ) - $MESSAGE" | tee -a /var/log/jenkins/reproducible-remote-error.log
	echo "Sleeping 5m before aborting the job."
	sleep 5m
	exec /srv/jenkins/bin/abort.sh
	exit 0
}

choose_package() {
	echo "$(date -u ) - about to choose a package to be build"
	# every 2 days we check for new archlinux packages
	touch -d "$(date -d '2 days ago' '+%Y-%m-%d') 00:00 UTC" $DUMMY
	if [ ! -f $ARCHLINUX_PKGS ] || [ $DUMMY -nt $ARCHLINUX_PKGS ] ; then
		echo "$(date -u ) - updating list of available packages."
		local SESSION="archlinux-scheduler-$RANDOM"
		schroot --begin-session --session-name=$SESSION -c jenkins-reproducible-archlinux
		schroot --run-session -c $SESSION --directory /var/abs/core -- ls -1|sort -R|xargs echo > $ARCHLINUX_PKGS
		schroot --end-session -c $SESSION
	fi
	rm $DUMMY > /dev/null
	echo "$(date -u ) - these packages are known to us:"
	cat $ARCHLINUX_PKGS
	for PKG in $(cat $ARCHLINUX_PKGS) ; do
		# build package if it has never build or at least a week ago
		if [ ! -d $BASE/archlinux/$PKG ] || [ ! -z $(find $BASE/archlinux/ -name $PKG -mtime +6) ] ; then
			SRCPACKAGE=$PKG
			echo "$(date -u ) - building package $PKG now..."
			# very simple locking…
			mkdir -p $BASE/archlinux/$PKG
			touch $BASE/archlinux/$PKG
			break
		fi
	done
	if [ -z $SRCPACKAGE ] ; then
		echo "$(date -u ) - no package found to be build, sleeping 6h."
		for i in $(seq 1 12) ; do
			sleep 30m
			echo "$(date -u ) - still sleeping..."
		done
		echo "$(date -u ) - exiting cleanly now."
		exit 0
	fi
}

first_build() {
	echo "============================================================================="
	echo "Building ${SRCPACKAGE} for Arch Linux on $(hostname -f) now."
	echo "Date:     $(date)"
	echo "Date UTC: $(date -u)"
	echo "============================================================================="
	set -x
	local SESSION="archlinux-$SRCPACKAGE-$(basename $TMPDIR)"
	local BUILDDIR="/tmp/$SRCPACKAGE-$(basename $TMPDIR)"
	local LOG=$TMPDIR/b1/$SRCPACKAGE/build1.log
	schroot --begin-session --session-name=$SESSION -c jenkins-reproducible-archlinux
	echo "MAKEFLAGS=-j$NUM_CPU" | schroot --run-session -c $SESSION --directory /tmp -u root -- tee -a /etc/makepkg.conf
	schroot --run-session -c $SESSION --directory /tmp -- mkdir $BUILDDIR
	schroot --run-session -c $SESSION --directory /tmp -- cp -r /var/abs/core/$SRCPACKAGE $BUILDDIR/
	# just set timezone in the 1st build
	echo 'export TZ="/usr/share/zoneinfo/Etc/GMT+12"' | schroot --run-session -c $SESSION --directory /tmp -- tee -a /var/lib/jenkins/.bashrc
	# nicely run makepkg with a timeout of 4h
	timeout -k 4.1h 4h /usr/bin/ionice -c 3 /usr/bin/nice \
		schroot --run-session -c $SESSION --directory $BUILDDIR/$SRCPACKAGE -- bash -l -c 'makepkg --syncdeps --noconfirm --skippgpcheck 2>&1' | tee -a $LOG
	PRESULT=${PIPESTATUS[0]}
	if [ $PRESULT -eq 124 ] ; then
		echo "$(date -u) - makepkg was killed by timeout after 4h." | tee -a $LOG
	fi
	schroot --end-session -c $SESSION
	if ! "$DEBUG" ; then set +x ; fi
}

second_build() {
	echo "============================================================================="
	echo "Re-Building ${SRCPACKAGE} for Arch Linux on $(hostname -f) now."
	echo "Date:     $(date)"
	echo "Date UTC: $(date -u)"
	echo "============================================================================="
	set -x
	local SESSION="archlinux-$SRCPACKAGE-$(basename $TMPDIR)"
	local BUILDDIR="/tmp/$SRCPACKAGE-$(basename $TMPDIR)"
	local LOG=$TMPDIR/b2/$SRCPACKAGE/build2.log
	NEW_NUM_CPU=$(echo $NUM_CPU-1|bc)
	schroot --begin-session --session-name=$SESSION -c jenkins-reproducible-archlinux
	echo "MAKEFLAGS=-j$NEW_NUM_CPU" | schroot --run-session -c $SESSION --directory /tmp -u root -- tee -a /etc/makepkg.conf
	schroot --run-session -c $SESSION --directory /tmp -- mkdir $BUILDDIR
	schroot --run-session -c $SESSION --directory /tmp -- cp -r /var/abs/core/$SRCPACKAGE $BUILDDIR/
	# add more variations in the 2nd build: TZ, LANG, LC_ALL, umask
	schroot --run-session -c $SESSION --directory /tmp -- tee -a /var/lib/jenkins/.bashrc <<-__END__
	export TZ="/usr/share/zoneinfo/Etc/GMT-14"
	export LANG="fr_CH.UTF-8"
	export LC_ALL="fr_CH.UTF-8"
	umask 0002
	__END__
	# nicely run makepkg with a timeout of 4h
	timeout -k 4.1h 4h /usr/bin/ionice -c 3 /usr/bin/nice \
		schroot --run-session -c $SESSION --directory $BUILDDIR/$SRCPACKAGE -- bash -l -c 'makepkg --syncdeps --noconfirm --skippgpcheck 2>&1' | tee -a $LOG
	PRESULT=${PIPESTATUS[0]}
	if [ $PRESULT -eq 124 ] ; then
		echo "$(date -u) - makepkg was killed by timeout after 4h." | tee -a $LOG
	fi
	schroot --end-session -c $SESSION
	if ! "$DEBUG" ; then set +x ; fi
}

remote_build() {
	local BUILDNR=$1
	local NODE=profitbricks-build3-amd64.debian.net
	local PORT=22
	set +e
	ssh -p $PORT $NODE /bin/true
	RESULT=$?
	# abort job if host is down
	if [ $RESULT -ne 0 ] ; then
		SLEEPTIME=$(echo "$BUILDNR*$BUILDNR*5"|bc)
		echo "$(date -u) - $NODE seems to be down, sleeping ${SLEEPTIME}min before aborting this job."
		sleep ${SLEEPTIME}m
		exec /srv/jenkins/bin/abort.sh
	fi
	ssh -p $PORT $NODE /srv/jenkins/bin/reproducible_build_archlinux_pkg.sh $BUILDNR ${SRCPACKAGE} ${TMPDIR}
	RESULT=$?
	if [ $RESULT -ne 0 ] ; then
		ssh -p $PORT $NODE "rm -r $TMPDIR" || true
		handle_remote_error "with exit code $RESULT from $NODE for build #$BUILDNR for ${SRCPACKAGE}"
	fi
	rsync -e "ssh -p $PORT" -r $NODE:$TMPDIR/b$BUILDNR $TMPDIR/
	RESULT=$?
	if [ $RESULT -ne 0 ] ; then
		echo "$(date -u ) - rsync from $NODE failed, sleeping 2m before re-trying..."
		sleep 2m
		rsync -e "ssh -p $PORT" -r $NODE:$TMPDIR/b$BUILDNR $TMPDIR/
		RESULT=$?
		if [ $RESULT -ne 0 ] ; then
			handle_remote_error "when rsyncing remote build #$BUILDNR results from $NODE"
		fi
	fi
	ls -R $TMPDIR
	ssh -p $PORT $NODE "rm -r $TMPDIR"
	set -e
}

#
# below is what controls the world
#

TMPDIR=$(mktemp --tmpdir=/srv/reproducible-results -d)  # where everything actually happens
trap cleanup_all INT TERM EXIT
cd $TMPDIR

DATE=$(date -u +'%Y-%m-%d %H:%M')
START=$(date +'%s')
BUILDER="${JOB_NAME#reproducible_builder_}/${BUILD_ID}"
ARCHLINUX_PKGS=/srv/reproducible-results/.archlinux_pkgs
DUMMY=$(mktemp -t archlinux-dummy-XXXXXXXX)

#
# determine mode
#
if [ "$1" = "" ] ; then
	MODE="master"
elif [ "$1" = "1" ] || [ "$1" = "2" ] ; then
	MODE="$1"
	SRCPACKAGE="$2"
	TMPDIR="$3"
	[ -d $TMPDIR ] || mkdir -p $TMPDIR
	cd $TMPDIR
	mkdir -p b$MODE/$SRCPACKAGE
	if [ "$MODE" = "1" ] ; then
		first_build
	else
		second_build
	fi
	# preserve results and delete build directory
	mv -v /tmp/$SRCPACKAGE-$(basename $TMPDIR)/$SRCPACKAGE/*.pkg.tar.xz $TMPDIR/b$MODE/$SRCPACKAGE/ || ls /tmp/$SRCPACKAGE-$(basename $TMPDIR)/$SRCPACKAGE/
	rm -r /tmp/$SRCPACKAGE-$(basename $TMPDIR)/
	echo "$(date -u) - build #$MODE for $SRCPACKAGE on $HOSTNAME done."
	exit 0
fi

#
# main - only used in master-mode
#
delay_start # randomize start times
# first, we need to choose a package…
SRCPACKAGE=""
choose_package
# build package twice
mkdir b1 b2
remote_build 1
# only do the 2nd build if the 1st produced some results
if [ ! -z "$(ls $TMPDIR/b1/$SRCPACKAGE/*.pkg.tar.xz 2>/dev/null|| true)" ] ; then
	remote_build 2
	# run diffoscope on the results
	TIMEOUT="30m"
	DIFFOSCOPE="$(schroot --directory /tmp -c source:jenkins-reproducible-${DBDSUITE}-diffoscope diffoscope -- --version 2>&1)"
	echo "$(date -u) - Running $DIFFOSCOPE now..."
	cd $TMPDIR/b1/$SRCPACKAGE
	for ARTIFACT in *.pkg.tar.xz ; do
		[ -f $ARTIFACT ] || continue
		call_diffoscope $SRCPACKAGE $ARTIFACT
		# publish page
		if [ -f $TMPDIR/$SRCPACKAGE/$ARTIFACT.html ] ; then
			cp $TMPDIR/$SRCPACKAGE/$ARTIFACT.html $BASE/archlinux/$SRCPACKAGE/
		fi
	done
fi
# publish logs
cd $TMPDIR/b1/$SRCPACKAGE
cp build1.log $BASE/archlinux/$SRCPACKAGE/
[ ! -f $TMPDIR/b2/$SRCPACKAGE/build2.log ] || cp $TMPDIR/b2/$SRCPACKAGE/build2.log $BASE/archlinux/$SRCPACKAGE/
echo "$(date -u) - $REPRODUCIBLE_URL/archlinux/$SRCPACKAGE/ updated."

cd
cleanup_all
trap - INT TERM EXIT
