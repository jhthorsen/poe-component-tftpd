use inc::Module::Install;

name q(POE-Component-TFTPd);
all_from q(lib/POE/Component/TFTPd.pm);

requires q(POE) => 1.284;
requires q(POE::Wheel::UDP) => 0.02;
test_requires q(Test::More) => 0.94;

bugtracker 'http://rt.cpan.org/NoAuth/Bugs.html?Dist=POE-Component-TFTPd';
repository 'git://github.com/jhthorsen/poe-component-tftpd.git';

auto_install;
WriteAll;
