AC_PREREQ(2.59)

AC_INIT(kavoom,m4_esyscmd_s([
	read -r debian_version <debian/changelog
	debian_version=${debian_version#*\(}
	debian_version=${debian_version%%\)*}
	echo "${debian_version%-*}"
]),[wsl-kavoom-bugs@fruit.je])
AM_INIT_AUTOMAKE([foreign subdir-objects dist-xz no-dist-gzip])

AC_CONFIG_SRCDIR(bin/kavoom.pl)

AC_PROG_INSTALL

AC_PATH_PROG(PERL, perl)
case $PERL in '')
	AC_MSG_ERROR([cannot find perl in your PATH.])
esac

AC_CONFIG_FILES([Makefile config.pl])
AC_OUTPUT
