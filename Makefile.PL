use inc::Module::Install;

name     q(POE-Component-TFTPd);
all_from q(lib/POE/Component/TFTPd.pm);

requires      q(POE::Wheel::UDP)     => 0;
requires      q(POE::Filter::Stream) => 0;
test_requires q(Test::Simple)        => 0.44;
no_index      q(directory)           => q(examples);

WriteAll;
