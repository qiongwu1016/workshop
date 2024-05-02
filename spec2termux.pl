#!/usr/bin/env perl

use v5.10.1;
use strict;
use warnings;

use List::MoreUtils qw( uniq );
use Data::Dumper;
use Devel::Confess;
use File::Path qw(make_path);
use Digest::SHA qw(sha256_hex);
use Getopt::Long;

sub sh ($);
sub safe_mkdir ($);
sub safe_cd ($);
sub new_file ($);
sub write_file ($$);
sub append_to_file($$);
sub process_val ($);
sub add_val ($$$);
sub expand_macros ($);
sub gen_tm_pkg_name ($);
sub to_tm_pkg ($);
sub gen_tarball_sha256 ($$);
sub indent($$);
sub amend_make_cmds($);

my $tarball_dir;

GetOptions("tarball_dir=s" => \$tarball_dir)
    or die("Error in command line arguments\n");

my $main_pkg = {};

my $pkg = $main_pkg;

my %pkgs = (
    main => $pkg,
);

my %to_tm_pkg_names = (
    'glibc' => 'glibc-repo',
    'glibc-dev' => 'glibc-repo',
    'zlib' => 'zlib',
    'zlib-dev' => 'zlib1g-dev',
    'bzip2-libs' => 'libzip',
    'bzip2-dev' => 'libbz2',
    'xz-dev' => 'xz-utils',
    'libbz2-dev' => 'libbz2',
    'xz-libs' => 'xz-utils',
    'gcc-c++' => '',
    'ibstdc++6' => 'libc++',
    'gcc' => '',
    'libstdc++' => 'libc++',
    'avahi-dev' => '',
    'avahi-libs' => '',
    'nss-dev' => 'libnss',
    'gettext-dev' => 'gettext',
    'openssl-dev' => 'openssl',
    'openssl' => 'openssl',
    'mpfr-dev' => 'mpfr',
    'mpfr' => 'mpfr',
    'ncurses-libs' => 'ncurses',
    'expat' => 'libexpat',
    'gmp' => 'libgmp',
    'pkgconfig' => 'pkg-config',
    'libxml2' => 'libxml2',
    'libxslt' => 'libxslt',
    'readline' => 'readline',
    'uuid' => 'libuuid',
    'uuid-dev' => 'libuuid',
    'openssl' => 'openssl',
    'readline-dev' => 'readline',
    'openssl-dev' => 'openssl',
    'gd-dev' => 'libgd',
    'openresty-elfutils-dev' => 'elfutils',
    'openresty-elfutils' => 'elfutils',
    'openresty-binutils' => 'binutils', 
    'openresty-saas-zlib' => 'zlib',
    'openresty-libbpf-dev' => 'openresty-libbpf',
    'openresty-binutils-dev' => 'binutils',
    'openresty-saas-zlib-dev' => 'zlib',
    'libcap-dev' => 'libcap',
);

my %macros = (
    cmake => 'cmake -DCMAKE_C_FLAGS_RELEASE:STRING=-DNDEBUG '
        . '-DCMAKE_CXX_FLAGS_RELEASE:STRING=-DNDEBUG '
        . '-DCMAKE_Fortran_FLAGS_RELEASE:STRING=-DNDEBUG '
        . '-DCMAKE_VERBOSE_MAKEFILE:BOOL=ON -DBUILD_SHARED_LIBS:BOOL=ON '
        . '-DLIB_SUFFIX=64',
    _prefix => '${TERMUX_PREFIX}',
    _lib => '${TERMUX_PREFIX}/lib64',
    _builddir => '.',
    _bindir => '${TERMUX_PREFIX}/bin',
    _libdir => '${TERMUX_PREFIX}/lib64',
    buildroot => '${TERMUX_PKG_MASSAGEDIR}',
    libbpf_prefix => '${TERMUX_PREFIX}',
    elf_prefix => '${TERMUX_ROOT}/usr/include/elfutils',
    or_zlib_prefix => '${TERMUX_ROOT}/usr/include',
    binutils_prefix => '${TERMUX_ROOT}/usr/opt/binutils',
);

my %license_mapping = (
    'LGPLv2' => 'LGPL-2.1',
);

my @keys = (
    qw(
        Name Version Release Summary Group License URL BuildRequires
        Requires AutoReqProv BuildRoot Provides
    ),
    qr/Source\d*/, qr/Patch\d*/,
);

my $in_section;
my $macro_cont;
my $val_ref;

while (<>) {
    if ($macro_cont) {
        if (! s/\s*\\\s*$/ /s) {
            $$val_ref .= expand_macros $_;
            undef $macro_cont;
            undef $val_ref;

        } else {
            chomp;
            $$val_ref .= expand_macros $_;
        }
        next;
    }

    next if /^\s*$/ || /^\s*\#.*/;

    my $done;
    for my $key_pat (@keys) {
        if (/^($key_pat)\s*:\s*(.*)/) {
            my ($k, $v) = ($1, $2);
            add_val $pkg, $k, process_val $v;
            $done = 1;
            last;
        }
    }
    next if $done;

    if (/^\s*%(?:define|global)\s+(\w+)\s*(.*)/) {
        my ($name, $val) = ($1, $2);
        next if defined $macros{$name};
        if ($val =~ s/\s*\\\s*$/ /s) {
            #warn "value: $val";
            $macros{$name} = expand_macros $val;
            $macro_cont = 1;
            $val_ref = \$macros{$name};

        } else {
            $macros{$name} = expand_macros $val;
        }
        next;
    }

    if (/^\s*%undefine\s+(\w+)\s*$/) {
        my $name = $1;
        delete $macros{$name};
        next;
    }

    if (/^\s*%if\b(.*)/) {
        my $cond = $1;
        if ($cond =~ s/\s*\\\s*$/ /s) {
            #warn "value: $val";
            $macro_cont = 1;
            $val_ref = \$cond;
        }
        next;
    }

    if (/^\s*%(?:else|endif)\s*$/) {
        next;
    }

    if (/^\s*%debug_package\s*$/) {
        next;
    }

    if (/^\s*(?:buildarch|autoreq|autoprov):\s+\S+/i) {
        next;
    }

    if (/^\s*\%(package|description|build|install|prep|files|changelog|clean
                |pre|post|preun|postun)(?:\s+(\S+))?\s*$/x)
    {
        my ($section, $sub_pkg) = ($1, $2);

        if ($section eq 'package') {
            if (!defined $sub_pkg) {
                die "missing package name in \%package";
            }

            $pkg = {};
            $pkgs{$sub_pkg} = $pkg;
            next;
        }

        if (defined $sub_pkg) {
            #warn "$section: $sub_pkg";
            $pkg = $pkgs{$sub_pkg};
            if (!defined $pkg) {
                die "Sub-package '$sub_pkg' not defined yet";
            }

            $in_section = 1;

        } else {
            $pkg = $main_pkg;
        }

        $pkg->{$section} = '';
        $val_ref = \$pkg->{$section};
        $in_section = 1;
        next;
    }

    if ($in_section) {
        if (/^\s*\%\w+/
            && !/^\s*\%(?:defattr|config|doc|dir|setup\d*|exclude|attr|patch\d*
                 |cmake)\b/x)
        {
            die "unknown section: $_";
        }

        $$val_ref .= expand_macros $_;
        next;
    }

    chomp;
    die "unknown line: $_";
}

my $name = $main_pkg->{Name};

if (!defined $name) {
    die "No Name section found for the main package";
}

if ($name =~ /[^-\w.]/) {
    die "bad package name '$name'";
}

if (! -d 'termux-scripts/') {
    safe_mkdir 'termux-scripts';
}

safe_cd 'termux-scripts';

if (! -d $name) {
    safe_mkdir $name;
}

safe_cd $name;

#write the build.sh file
{
    my $out = new_file 'build.sh';
    $main_pkg->{description} =~ s/\n+/ /g;
    my $license = $main_pkg->{License};
    if (exists $license_mapping{$license}) {
        $license = $license_mapping{$license};
    }
    print $out <<_EOC_;
#!/bin/bash
set -x
TERMUX_PKG_HOMEPAGE="$main_pkg->{URL}"
TERMUX_PKG_DESCRIPTION="$main_pkg->{description}"
TERMUX_PKG_LICENSE="$license"
TERMUX_PKG_MAINTAINER="qiong.wu\@openresty.com"
TERMUX_PKG_VERSION="$main_pkg->{Version}"
TERMUX_PKG_REVISION=2
TERMUX_PKG_SRCURL="\$TERMUX_PKG_TARBALL_DIR/$name-$main_pkg->{Version}.tar.gz"
_EOC_
    
    for my $key (reverse sort keys %pkgs) {
        #print "\$key: $key\n";
        next if $key ne 'main';
        my $pkg_data = $pkgs{$key};

        #write pkg tarball sha256
        chomp($tarball_dir); # Remove the newline character at the end of the input

        my $checksum = gen_tarball_sha256($tarball_dir, "$name-$main_pkg->{Version}.tar.gz");
        print $out "TERMUX_PKG_SHA256=$checksum\n";
        #write the dependencies
        my (@tm_dep_pkgs, @tm_deps);
        my $deps = $pkg_data->{Requires};
        if (defined $deps) { 
            if (!ref $deps) {
                $deps = [$deps];
            }
            for my $deps (@$deps) {
                my @deps = split /\s*,\s*/s, $deps;
                for my $dep (@deps) {
                    $dep =~ s/^\s+|\s+$//gs;
                    print "\$dep: $dep\n";
                    my ($tm_pkg, $tm_dep) = to_tm_pkg $dep;
                    print "\$deb_pkg: $tm_pkg, \$deb_dep: $tm_dep\n";
                    if ($tm_pkg ne '') {
                        push @tm_deps, $tm_dep;
                        push @tm_dep_pkgs, $tm_pkg;
                    }
                }
            }
        }
        if (@tm_dep_pkgs) {
            my $deps_str = join ', ', @tm_dep_pkgs;
            print $out "TERMUX_PKG_DEPENDS=\"$deps_str\"\n";
        }

        #write the build dependencies
        my $build_deps = $pkg_data->{BuildRequires};
        my (@tm_build_dep_pkgs, @tm_build_deps);
        if (defined $build_deps) {
            if (!ref $build_deps) {
                $build_deps = [$build_deps];
            }

            for my $deps (@$build_deps) {
                my @deps = split /\s*,\s*/, $deps;
                for my $dep (@deps) {
                    $dep =~ s/^\s+|\s+$//g;
                    my ($tm_pkg, $tm_dep) = to_tm_pkg $dep;
                    if ($tm_pkg ne '') {
                        push @tm_build_deps, $tm_dep;
                        push @tm_build_dep_pkgs, $tm_pkg;
                    }
                }
            }
        }

        @tm_build_dep_pkgs = uniq @tm_build_dep_pkgs;
        @tm_build_deps = uniq @tm_build_deps;
        if (@tm_build_dep_pkgs) {
            my $deps_str = join ', ', @tm_build_dep_pkgs;
            print $out "TERMUX_PKG_BUILD_DEPENDS=\"$deps_str\"\n";
        }
	}

    #write TERMUX_PREFIX AND TERMUX_PREFIX_CLASSICAL
    print $out <<'_EOC_';
TERMUX_PREFIX=$TERMUX_ROOT/opt
TERMUX_PREFIX_CLASSICAL=$TERMUX_PREFIX
_EOC_

    #write termux_step_make()
    my $build = $main_pkg->{build};
    if (defined $build) {
        $build =~ s/(\w+)='(.*?)(?<!\\)'/$1="$2"/gs;
        my $build_cmds = indent(amend_make_cmds($build), 4);
        print $out <<"_EOC_";

termux_step_make() {
$build_cmds
}
_EOC_
    }

    #wrtie termux_step_make_install()
    my $install = $main_pkg->{install};
    if (defined $install) {
        $install =~ s/(\w+)='(.*?)(?<!\\)'/$1="$2"/gs; 
        my $install_cmds = indent(amend_make_cmds($install), 4);
        print $out <<"_EOC_";

termux_step_make_install() {
$install_cmds
}
_EOC_
    }
    

	close $out;
}

sub indent ($$) {
    my ($value, $size) = @_;
    my $s = ' ' x $size;
    $value =~ s/^/$s/mg;
    return $value;
}

sub amend_make_cmds ($) {
    my $make_cmds = shift;
    $make_cmds = expand_macros($make_cmds);
    $make_cmds =~ s/-C\s+src/-C \$TERMUX_PKG_SRCDIR\/src/g;
    $make_cmds =~ s/(?<=make )(?!\-C)/-C \${TERMUX_PKG_SRCDIR} /g;
    return $make_cmds;
}

sub gen_tarball_sha256 ($$) {
    my ($tarball_dir, $tarball_file) = @_;

    my $full_path = "$tarball_dir/$tarball_file";

    print "full path: $full_path\n";

    open(my $fh, '<:raw', $full_path) or die "Can't open '$full_path': $!";

    my $sha256 = Digest::SHA->new(256);

    $sha256->addfile($fh);

    close($fh);

    return $sha256->hexdigest;
}

sub gen_tm_pkg_name ($) {
    my $key = shift;

    my $pkg_name;
    if ($key eq 'main') {
        $pkg_name = $name;

    } else {
        $pkg_name = "$name-$key";
        $pkg_name =~ s/-devel$/-dev/;
    }

    return $pkg_name;
}

sub to_tm_pkg ($) {
    my $dep = shift;
    if ($dep !~ /^([^\s><=]+)/) {
        die "Bad dependency: $dep";
    }
    my $pkg_name = $1;
    my $changed;
    if ($pkg_name =~ s/-devel$/-dev/g) {
        $changed = 1;
    }
    #warn "checking pkg name $pkg_name";
    my $name = $to_tm_pkg_names{$pkg_name};
    if (defined $name) {
        #warn "found new name: $name";
        $pkg_name = $name;
        $changed = 1;
    }

    if ($changed) {
        $dep =~ s/^([^\s><=]+)/$pkg_name/;
    }
    if ($dep =~ s/([><=].*)/($1)/) {
        # strip release numbers for deb deps
        $dep =~ s/-\d+\)$/)/;
    }
    $dep =~ s/\(\s*=\s*/(>= /;
    #warn "returning $pkg_name $dep";
    return ($pkg_name, $dep);
}

sub write_file ($$) {
    my ($fname, $content) = @_;

    my $out = new_file $fname;
    print $out $content;
    close $out;
}

sub new_file ($) {
    my $fname = shift;
    open my $out, ">$fname"
        or die "Cannot open $fname for writing: $!\n";
    return $out;
}

sub sh ($) {
    my $cmd = shift;
    system($cmd) == 0
        or die "failed to run cmd '$cmd': $?";
}

sub safe_mkdir ($) {
    my $dir = shift;
    mkdir $dir or die "failed to mkdir '$dir': $!";
}

sub safe_cd ($) {
    my $dir = shift;
    chdir $dir or die "failed to chdir to '$dir': $!";
}

sub expand_macros ($) {
    my $v = shift;
    my $s = '';
    while (1) {
        if ($v =~ /\G ([^\%\$]+) /gcmsx) {
            $s .= $1;

        } elsif ($v =~ /\G ( \$ (?:\{ (\w+) \} | (\w+) ) ) /gcmsx) {
            my $whole = $1;
            my $var = $2 // $3;
            if ($var eq 'RPM_BUILD_ROOT') {
                $s .='$(DESTDIR)';

            } else {
                $s .= $whole;
            }

        } elsif ($v =~ /\G ( \% (?: \{ ( [^\n]*? ) \} | (\w+) ) ) /gcmsx) {
            my $whole = $1;
            my $var = $2 // $3;

            if ($var =~ /^SOURCE\d*$/) {
                $var = ucfirst lc $var;
                my $sec = $main_pkg->{$var};
                if (!defined $sec) {
                    die "$var is never defined but is used";
                }
                $s .= $sec;

            } elsif ($var =~ s/^\?//) {
                my $val = $macros{$var};
                if (! defined $val) {
                    $s .= '';

                } else {
                    $s .= $val;
                }

            } elsif ($var =~ s/^!\?.*?://) {
                die "TODO: $var";
                $s .= expand_macros $var;

            } else {
                my $val = $macros{$var};
                if (defined $val) {
                    $s .= $val;

                } else {
                    $s .= $whole;
                }
            }

        } elsif ($v =~ /\G (.) /gcmsx) {
            $s .= $1;

        } else {
            last;
        }
    }
    return $s;
}

sub process_val ($) {
    my $v = shift;
    $v =~ s/^\s+|\s+$//g;
    expand_macros $v;
}

sub add_val ($$$) {
    my ($pkg, $key, $val) = @_;

    if ($key =~ /^(?:Version|Name|Release)$/) {
        my $k = lc $key;
        $macros{$k} = $val;
    }

    my $old_val = $pkg->{$key};
    if (!defined $old_val) {
        $pkg->{$key} = $val;
        return;
    }
    if (ref $old_val) {
        push @$old_val, $val;
        return;
    }
    $pkg->{$key} = [$old_val, $val];
}
