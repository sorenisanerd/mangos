#!/bin/sh
set -e

mkdir -p ${OUTPUTDIR}/debian/pool
cd $SRCDIR/out
mv *.deb ${OUTPUTDIR}/debian/pool/
cd ${OUTPUTDIR}/debian

apt-ftparchive packages pool > ${OUTPUTDIR}/debian/Packages
apt-ftparchive release pool > ${OUTPUTDIR}/debian/Release

PS1="\t \u@\h:\w\$ "
