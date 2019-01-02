# -*- mode: perl; -*-
# process this file with cpanm --installdeps -q .

$ENV{SQLITE_MAX_LENGTH} = 2147483647;

requires perl => '5.10.1';

requires 'DBD::SQLite' => '1.59';
requires 'File::Copy::Recursive' => '0.44';
requires 'IO::Compress::Lzma' => '2.081';
requires 'LWP' => '6.00';
requires 'LWP::Protocol::https' => '6.07';
