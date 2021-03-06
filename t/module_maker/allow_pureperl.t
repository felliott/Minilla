use strict;
use warnings;
use utf8;
use Test::More;
use t::Util;

use Minilla::Profile::ModuleBuild;
use Minilla::Project;

test(1, sub {
    my $build_pl = slurp('Build.PL');
    like($build_pl, qr{allow_pureperl\s+=>\s+1});
    like($build_pl, qr{'Module::Build'\s+=>\s+0\.4005});
});
test(0, sub {
    my $build_pl = slurp('Build.PL');
    like($build_pl, qr{allow_pureperl\s+=>\s+0});
    like($build_pl, qr{'Module::Build'\s+=>\s+0\.38});
});

done_testing;

sub test {
    my $allow = shift;
    my $code = shift;

    my $guard = pushd(tempdir());

    Minilla::Profile::ModuleBuild->new(
        author => 'hoge',
        dist => 'Acme-Foo',
        module => 'Acme::Foo',
        path => 'Acme/Foo.pm',
        version => '0.01',
    )->generate();

    spew('MANIFEST', <<'...');
    Build.PL
    lib/Acme/Foo.pm
...
    write_minil_toml({
        name => 'Acme-Foo',
        allow_pureperl => $allow,
    });
    git_init_add_commit();
    Minilla::Project->new()->regenerate_files();
    git_init_add_commit();
    $code->();
}
