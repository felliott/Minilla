package Minilla::Project;
use strict;
use warnings;
use utf8;

use TOML 0.92 qw(from_toml);
use File::Basename qw(basename dirname);
use File::Spec::Functions qw(catdir catfile);
use DirHandle;
use File::pushd;
use CPAN::Meta;
use Module::CPANfile;
use Config::Identity::PAUSE;
use Module::Runtime qw(require_module);

use Minilla;
use Minilla::Logger;
use Minilla::Metadata;
use Minilla::WorkDir;
use Minilla::ReleaseTest;
use Minilla::ModuleMaker::ModuleBuild;
use Minilla::ModuleMaker::ModuleBuildTiny;
use Minilla::ModuleMaker::ExtUtilsMakeMaker;
use Minilla::Util qw(slurp_utf8 find_dir cmd spew_raw slurp_raw);
use Encode qw(decode_utf8);

use Moo;

has dir => (
    is => 'rw',
    builder => 1,
    trigger => 1,
    required => 1,
);

has module_maker => (
    is => 'ro',
    default => sub {
        my $self = shift;
        if ($self->config && defined($self->config->{module_maker})) {
            # Automatic require.
            my $klass = $self->config->{module_maker};
            $klass = $klass =~ s/^\+// ? $klass : "Minilla::ModuleMaker::$klass";
            return $klass->new();
        }
        Minilla::ModuleMaker::ModuleBuild->new()
    },
    lazy => 1,
);

has dist_name => (
    is => 'lazy',
);

has build_class => (
    is => 'lazy',
);

has main_module_path => (
    is => 'lazy',
);

has metadata => (
    is => 'lazy',
    required => 1,
    handles => [qw(name perl_version license)],
    clearer => 1,
);

has contributors => (
    is => 'lazy',
);

has work_dir => (
    is => 'lazy',
);

has files => (
    is => 'lazy',
);

has no_index => (
    is => 'ro',
    default => sub {
        my $self = shift;
        exists $self->config->{no_index} ?
            $self->config->{no_index} :
            {
                directory => [qw(
                    t xt inc share eg examples author builder
                ) ]
            };
    },
);

has script_files => (
    is => 'ro',
    default => sub {
        my $self = shift;
        my $script_files = exists $self->config->{script_files} ?
            $self->config->{script_files} :
            ['script/*', 'bin/*'];
        join ', ', map { "glob('$_')" } @$script_files;
    },
);

no Moo;

sub allow_pureperl {
    my $self = shift;
    $self->config->{allow_pureperl} ? 1 : 0;
}

sub module_build_version {
    my $self = shift;
    # --pureperl-only support was added in 0.4005
    $self->allow_pureperl ? 0.4005 : 0.38;
}

sub version {
    my $self = shift;
    my $version = $self->config->{version} || $self->metadata->version;
    unless (defined $version) {
        errorf("Minilla can't aggregate version number from '" . $self->main_module_path . '"');
    }
    return $version;
}

sub authors {
    my $self = shift;
    if (my $authors_from = $self->config->{authors_from}) {
        my $meta = Minilla::Metadata->new(
            source => $authors_from
        );
        return $meta->authors;
    }
    $self->config->{authors} || $self->metadata->authors;
}

sub abstract {
    my $self = shift;
    if (my $abstract_from = $self->config->{abstract_from}) {
        my $meta = Minilla::Metadata->new(
            source => $abstract_from
        );
        return $meta->abstract;
    }
    $self->config->{abstract} || $self->metadata->abstract;
}

sub badges {
    my $self = shift;
    $self->config->{badges} || [];
}

sub tap_harness_args {
    my $self = shift;
    $self->config->{tap_harness_args};
}

sub use_xsutil {
    my $self = shift;
    return defined $self->config->{XSUtil} ? 1 : 0;
}

sub needs_compiler_c99 {
    my $self = shift;
    if( my $xsutil = $self->config->{XSUtil} ){
        return $xsutil->{needs_compiler_c99} ? 1 : 0;
    }
}

sub needs_compiler_cpp {
    my $self = shift;
    if( my $xsutil = $self->config->{XSUtil} ){
        return $xsutil->{needs_compiler_cpp} ? 1 : 0;
    }
}

sub generate_ppport_h {
    my $self = shift;
    if( my $xsutil = $self->config->{XSUtil} ){
        return $xsutil->{generate_ppport_h} || 0;
    }
}

sub generate_xshelper_h {
    my $self = shift;
    if( my $xsutil = $self->config->{XSUtil} ){
        return $xsutil->{generate_xshelper_h} || 0;
    }
}

sub cc_warnings{
    my $self = shift;
    if( my $xsutil = $self->config->{XSUtil} ){
        return $xsutil->{cc_warnings} ? 1 : 0;
    }
}

sub _build_dir {
    my $self = shift;

    my $gitdir = find_dir('.git')
        or errorf("Current directory is not in git(%s)\n", Cwd::getcwd());
    $gitdir = File::Spec->rel2abs($gitdir);
    my $base_dir = dirname($gitdir);

    return $base_dir;
}

sub _trigger_dir {
    my ($self, $dir) = @_;
    unless (File::Spec->file_name_is_absolute($dir)) {
        $self->dir(File::Spec->rel2abs($dir));
    }
}

sub config {
    my $self = shift;

    my $toml_path = File::Spec->catfile($self->dir, 'minil.toml');
    if (-f $toml_path) {
        my ($conf, $err) = from_toml(slurp_utf8($toml_path));
        if ($err) {
            errorf("TOML error in %s: %s\n", $toml_path, $err);
        }
        $conf;
    } else {
        +{};
    }
}

sub c_source {
    my $self = shift;
    $self->config->{c_source} ? join(' ', @{$self->config->{c_source}}) : '';
}

sub _build_dist_name {
    my $self = shift;

    my $dist_name;
    if ($self->config && defined($self->config->{name})) {
        my $conf = $self->config;
        if ($conf->{name} =~ /::/) {
            (my $better_name = $conf->{name}) =~ s/::/-/g;
            Carp::croak(qq!You shouldn't set 'name="$conf->{name}"' in minil.toml. You need to set the value as 'name="$better_name"'.!);
        }
        $dist_name = $conf->{name};
    }
    unless (defined $dist_name) {
        infof("Detecting project name from directory name.\n");
        $dist_name = $self->_detect_project_name_from_dir;
    }
    if ($dist_name eq '.') { Carp::confess("Heh? " . $self->dir); }

    unless ($dist_name) {
        errorf("Cannot detect distribution name from minil.toml or directory name(cwd: %s, dir:%s)\n", Cwd::getcwd(), $self->dir);
    }

    return $dist_name;
}

sub _detect_project_name_from_dir {
    my $self = shift;

    local $_ = basename($self->dir);
    $_ =~ s!--!-!g;
    $_ =~ s!\Ap5-!!;
    return $_;
}

sub _build_build_class {
    my $self = shift;

    my $build_class;
    if (my $conf = $self->config) {
        $build_class = $conf->{build}{build_class};
    }

    return $build_class if $build_class;

    return $self->use_xsutil ? 'Module::Build::XSUtil' : 'Module::Build';
}

sub _build_main_module_path {
    my $self = shift;

    my $dist_name = $self->dist_name;
    my $source_path = $self->_detect_source_path($dist_name);
    unless (defined($source_path) && -e $source_path) {
        errorf("%s not found.\n", $source_path || "main module($dist_name)");
    }

    infof("Retrieving meta data from %s.\n", $source_path);
    return $source_path;
}

sub _build_metadata {
    my $self = shift;

    my $config = +{%{$self->config}};
    if (my $license = delete $config->{license}) {
        $config->{_license_name} = $license;
    }

    # fill from main_module
    my $metadata = Minilla::Metadata->new(
        source => $self->main_module_path,
        %$config,
    );
    infof("Name: %s\n", $metadata->name);
    infof("Abstract: %s\n", $metadata->abstract);
    infof("Version: %s\n", $metadata->version);

    return $metadata;
}

sub _case_insensitive_match {
    my $path = shift;
    my @path = File::Spec->splitdir($path);
    my $realpath = '.';
    LOOP: for my $part (@path) {
        my $d = DirHandle->new($realpath)
            or do {
            # warn "Cannot open dirhandle";
            return;
        };
        while (defined($_ = $d->read)) {
            if (uc($_) eq uc($part)) {
                $realpath = catfile($realpath, $_);
                next LOOP;
            }
        }

        # does not match
        # warn "Does not match: $part in $realpath";
        return undef;
    }
    return $realpath;
}

sub format_tag {
    my ($self, $version) = @_;
    if (defined(my $format = $self->config->{tag_format})) {
        (my $tag = $format) =~ s/%v/$version/;
        $tag;
    } else {
        $version;
    }
}

sub _detect_source_path {
    my ($self, $dir) = @_;

    # like cpan-outdated => lib/App/cpanminus.pm
    my $pat2 = "App-" . do {
        local $_ = $dir;
        s!-!!;
        $_;
    };
    for my $path ("App-$dir", $pat2, $dir) {
        $path =~ s!::!/!g;
        $path =~ s!-!/!g;
        $path = "lib/${path}.pm";

        return $path if -f $path;

        $path = _case_insensitive_match($path);
        return $path if defined($path);
    }

    return undef;
}

sub load_cpanfile {
    my $self = shift;
    Module::CPANfile->load(catfile($self->dir, 'cpanfile'));
}

sub cpan_meta {
    my ($self, $release_status) = @_;
    $release_status ||= ($self->version =~ /_/ ? 'unstable' : 'stable');

    my $cpanfile = $self->load_cpanfile;
    my $merged_prereqs = $cpanfile->prereqs->with_merged_prereqs(
        CPAN::Meta::Prereqs->new($self->module_maker->prereqs($self))
    );
    $merged_prereqs = $merged_prereqs->with_merged_prereqs(
        CPAN::Meta::Prereqs->new(Minilla::ReleaseTest->prereqs)
    );
    if ($self->metadata->perl_version) {
        $merged_prereqs = $merged_prereqs->with_merged_prereqs(
            CPAN::Meta::Prereqs->new(+{
                runtime => {
                    requires => {
                        perl => $self->metadata->perl_version,
                    }
                }
            })
        );
    }
    $merged_prereqs = $merged_prereqs->as_string_hash;

    my $dat = {
        "meta-spec" => {
            "version" => "2",
            "url"     => "http://search.cpan.org/perldoc?CPAN::Meta::Spec"
        },
        license        => [ $self->license->meta2_name ],
        abstract       => $self->abstract,
        dynamic_config => 0,
        version        => $self->version,
        name           => $self->dist_name,
        prereqs        => $merged_prereqs,
        generated_by   => "Minilla/$Minilla::VERSION",
        release_status => $release_status || 'stable',
        no_index       => $self->no_index,
    };
    unless ($dat->{abstract}) {
        errorf("Cannot retrieve 'abstract' from %s. You need to write POD in your main module.\n", $self->dir);
    }
    if ($self->authors) {
        $dat->{author} = $self->authors;
    } else {
        errorf("Cannot determine 'author' from %s\n", $self->dir);
    }
    if ($self->contributors && @{$self->contributors} > 0) {
        $dat->{x_contributors} = $self->contributors;
    }
    if (my $authority = $self->config->{authority}) {
        $dat->{x_authority} = $authority;
    }

    # fill 'provides' section
    if ($release_status ne 'unstable') {
        my $provides = Module::Metadata->provides(
            dir     => File::Spec->catdir($self->dir, 'lib'),
            version => 2
        );
        unless (%$provides) {
            errorf("%s does not provides any package. Abort.\n", $self->dir);
        }
        $dat->{provides} = $provides;
    }

    # fill repository information
    my $git_info = $self->extract_git_info;
    if ($git_info->{bugtracker}) {
        $dat->{resources}->{bugtracker} = $git_info->{bugtracker};
    }
    if ($git_info->{repository}) {
        $dat->{resources}->{repository} = $git_info->{repository};
    }
    if ($git_info->{homepage}) {
        $dat->{resources}->{homepage}   = $git_info->{homepage};
    }

    my $meta = CPAN::Meta->new($dat);
    return $meta;
}

sub extract_git_info {
    my $self = shift;

    my $guard = pushd($self->dir);

    my $bugtracker;
    my $repository;
    my $homepage;
    if ( `git remote show -n origin` =~ /URL: (.*)$/m && $1 ne 'origin' ) {
        # XXX Make it public clone URL, but this only works with github
        my $registered_url = $1;
        if ($registered_url =~ /github\.com/) {
            my ($user, $repo) = $registered_url =~ m{
                github\.com
                (?:(?::[0-9]+)?/|:)([^/]+)
                /
                ([^/]+?)(?:\.git)?
                $
            }ix;
            my $git_url = "git://github.com/$user/$repo.git";
            my $http_url = "https://github.com/$user/$repo";
            unless ($self->config->{no_github_issues}) {
                $bugtracker = +{
                    web => "$http_url/issues",
                };
            }
            $repository = +{
                url => $git_url,
                web => $http_url,
            };
            $homepage = $self->config->{homepage} || $http_url;
        } else {
            if ($registered_url !~ m{^(?:https?|ssh|git)://}) {
                # We can't do much more than this, but we need to fix
                # user@host:path/to/repo.git to git://$host/path/to/repo.git in
                # order to work with CPAN::Meta
                $registered_url =~ s{
                    \A
                    [^@]+       # user name, which we toss away
                    @
                    ([^:]+)     # anything other than a ":"
                    :
                    (.+)        # anything, which is the repository
                    \Z
                }{git://$1/$2}gx;
            }

            # normal repository
            if ($registered_url !~ m{^file://}) {
                $repository = +{
                    url => $registered_url,
                };
            }
        }
    }

    return +{
        bugtracker => $bugtracker,
        repository => $repository,
        homepage   => $homepage,
    }
}

sub readme_from {
    my $self = shift;
    $self->config->{readme_from} || $self->main_module_path;
}

sub regenerate_files {
    my $self = shift;

    $self->regenerate_meta_json();
    $self->regenerate_readme_md();
    $self->module_maker->generate($self);
    if (Cwd::getcwd() ne $self->dir) {
        my $guard = pushd($self->dir);
        $self->module_maker->generate($self);
    }
}

sub regenerate_meta_json {
    my $self = shift;

    my $meta = $self->cpan_meta('unstable');
    $meta->save(File::Spec->catfile($self->dir, 'META.json'), {
        version => '2.0'
    });
}

sub generate_minil_toml {
    my ($self, $profile) = @_;

    my $fname        = File::Spec->catfile($self->dir, 'minil.toml');
    my $project_name = $self->_detect_project_name_from_dir;
    my $content      = join("\n",
        qq{name = "$project_name"},
        qq{# badges = ["travis"]},
    );

    my %pause;
    if (eval { %pause = Config::Identity::PAUSE->load; 1; } && exists $pause{user}) {
        my $user = uc($pause{user});
        $content .= qq{\nauthority="cpan:${user}"\n},
    }
    warn $@ if $@;

    if ($profile eq 'ModuleBuild') {
        $content .= qq{\nmodule_maker="ModuleBuild"\n};
    } elsif ($profile eq 'ExtUtilsMakeMaker') {
        $content .= qq{\nmodule_maker="ExtUtilsMakeMaker"\n};
    } else {
        $content .= qq{\nmodule_maker="ModuleBuildTiny"\n};
    }

    spew_raw($fname, $content . "\n");
}

sub regenerate_readme_md {
    my $self = shift;

    my $markdown_maker = $self->config->{markdown_maker} || 'Pod::Markdown';
    require_module($markdown_maker);
    if ($markdown_maker eq 'Pod::Markdown') {
        $markdown_maker->VERSION('1.322');
    }

    my $parser = $markdown_maker->new;
    if (not $parser->isa('Pod::Markdown')) {
        errorf("'markdown_maker' config key must be a subclass of Pod::Markdown\n");
    }
    $parser->parse_from_file($self->readme_from);

    my $fname = File::Spec->catfile($self->dir, 'README.md');
    my $markdown = $parser->as_markdown;

    if (ref $self->badges eq 'ARRAY' && scalar @{$self->badges} > 0) {
        my $user_name;
        my $repository_name;

        my $git_info = $self->extract_git_info;
        if (my $web_url = $git_info->{repository}->{web}) {
            ($user_name, $repository_name) = $web_url =~ m!https://.+/(.+)/(.+)!;
        }

        my @badges;
        if ($user_name && $repository_name) {
            for my $badge (@{$self->badges}) {
                if ($badge eq 'travis') {
                    push @badges, "[![Build Status](https://travis-ci.org/$user_name/$repository_name.svg?branch=master)](https://travis-ci.org/$user_name/$repository_name)";
                }
                if ($badge eq 'coveralls') {
                    push @badges, "[![Coverage Status](https://img.shields.io/coveralls/$user_name/$repository_name/master.svg?style=flat)](https://coveralls.io/r/$user_name/$repository_name?branch=master)"
                }
                if ($badge eq 'gitter') {
                    push @badges, "[![Gitter chat](https://badges.gitter.im/$user_name/$repository_name.png)](https://gitter.im/$user_name/$repository_name)";
                }
            }
        }

        $markdown = "\n" . $markdown;
        $markdown = join(' ', @badges) . $markdown
    }

    spew_raw($fname, $markdown);
}

sub verify_prereqs {
    my ($self) = @_;

    if ($Minilla::AUTO_INSTALL) {
        system('cpanm', '--quiet', '--installdeps', '--with-develop', '.');
    }
}

sub _build_contributors {
    my $self = shift;

    my $normalize = sub {
        local $_ = shift;
        if (/<([^>]+)>/) {
            $1;
        } else {
            $_;
        }
    };
    my @lines = do {
        my %uniq;
        reverse grep { !$uniq{$normalize->($_)}++ } split /\n/, `git log --format="%aN <%aE>"`
    };
    my %is_author = map { $normalize->($_) => 1 } @{$self->authors};
    @lines = map { decode_utf8($_) } @lines;
    @lines = grep { !$is_author{$normalize->($_)} } @lines;
    @lines = grep { $_ ne 'Your Name <you@example.com>' } @lines;
    @lines = grep { ! /^\(no author\) <\(no author\)\@[\d\w\-]+>$/ } @lines;
    \@lines;
}

sub _build_work_dir {
    my $self = shift;
    Minilla::WorkDir->new(
        project  => $self,
    );
}

sub _build_files {
    my $self = shift;
    my $conf = $self->config->{'FileGatherer'};
    my @files = Minilla::FileGatherer->new(
        exclude_match => $conf->{exclude_match},
        exists $conf->{include_dotfiles} ? (include_dotfiles => $conf->{include_dotfiles}) : (),
    )->gather_files(
        $self->dir
    );
    \@files;
}

sub perl_files {
    my $self = shift;
    my @files = @{$self->files};
    grep {
        $_ =~ /\.(?:pm|pl|t)$/i || slurp_raw($_) =~ m{ ^ \#\! .* perl }ix
    } @files;
}

sub PL_files { shift->config->{PL_files} || +{} }

sub requires_external_bin {
    my $self = shift;
    return $self->config->{requires_external_bin};
}

# @return true if the project is valid, false otherwise.
sub validate {
    my $self = shift;
    my $module_maker = $self->module_maker;
    if ($module_maker->can('validate')) {
        return $module_maker->validate();
    } else {
        return 1;
    }
}

1;
