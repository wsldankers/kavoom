AC_INIT([kavoom], [3.3])
AM_INIT_AUTOMAKE
AC_CONFIG_SRCDIR(bin/kavoom.pl)

AC_PROG_INSTALL

AC_PATH_PROG(PERL, perl)
case $PERL in '')
	AC_MSG_ERROR([cannot find perl in your PATH.])
esac

AC_CONFIG_FILES([Makefile config.pl])
AC_OUTPUT
