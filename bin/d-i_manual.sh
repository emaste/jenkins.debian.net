#!/bin/bash

# Copyright 2012 Holger Levsen <holger@layer-acht.org>
# released under the GPLv=2

set -x
set -e
export LC_ALL=C
export MIRROR=http://ftp.de.debian.org/debian
export http_proxy="http://localhost:3128"

#
# clean
#
rm -fv *.deb *.dsc *_*.build *_*.changes *_*.tar.gz

#
# prepare build
#
if [ -f /var/base.tgz ] ; then
	sudo pbuilder --create
else
	sudo pbuilder --update
fi

#
# build
#
cd manual
pdebuild
