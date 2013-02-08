bin_SCRIPTS = bin/kavoom
man_MANS = bin/kavoom.1

EXTRA_DIST = bin
CLEANFILES = bin/kavoom bin/kavoom.tmp bin/kavoom.1

.pl:
	mkdir -p $$(dirname $@)
	cat config.pl $^ >$@.tmp
	chmod 755 $@.tmp
	mv $@.tmp $@

.pl.1:
	mkdir -p $$(dirname $@)
	pod2man --utf8 $< $@

SUFFIXES = .pl .1
