
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME         => 'POE::Component::TFTPd',
    VERSION_FROM => 'lib/POE/Component/TFTPd.pm', # finds \$VERSION
    AUTHOR       => 'Jan Henning Thorsen (cpan@flodhest.net)',
    ABSTRACT     => 'Module abstract (<= 44 characters) goes here',
    PREREQ_PM    => {
                     'Test::Simple'        => 0.44,
                     'POE::Wheel::UDP'     => 0,
                     'POE::Filter::Stream' => 0,
                    },
);
