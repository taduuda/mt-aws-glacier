#!/bin/sh
cd .. && grep -s -q APP-MTAWS-ROOT-DIR Build.PL || exit 1 # protect from wrong dir
[ `which perl` = "/usr/bin/perl" ] || exit 1
perl Build.PL && ./Build build
DISTROS="precise quantal raring saucy"
for DISTRO in $DISTROS
do
rm -rf debian
mkdir -p debian/source
scripts/write_debian_files.pl ./packaging ubuntu $DISTRO
debuild -S
rm -rf debian
done

