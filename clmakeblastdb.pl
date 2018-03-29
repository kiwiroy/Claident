use strict;
use Fcntl ':flock';
use File::Spec;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use IO::Uncompress::Bunzip2 qw(bunzip2 $Bunzip2Error);
use IO::Uncompress::UnXz qw(unxz $UnXzError);

my $buildno = '0.2.x';

my $devnull = File::Spec->devnull();

my $makeblastdboption = ' -dbtype nucl -input_type fasta -hash_index -parse_seqids -max_file_sz 3G';

# options
my $numthreads = 1;
my $ngilist;
my $nseqidlist;
my %ngilist;
my %nseqidlist;
my $minlen;
my $maxlen;

# input/output
my $inputfile;
my $output;

# commands
my $makeblastdb;
my $blastdb_aliastool;

# global variables
my $maxsize = 4000000000;

# file handles
my $filehandleinput1;
my $filehandleinput2;
my $filehandleoutput1;
my $pipehandleinput1;

&main();

sub main {
	# print startup messages
	&printStartupMessage();
	# get command line arguments
	&getOptions();
	# check variable consistency
	&checkVariables();
	# read negative seqids list file
	&readNegativeSeqIDList();
	# split input file and run makeblastdb
	&splitInputFile();
	# make nal
	&makeNal();
	exit(0);
}

sub printStartupMessage {
	print(STDERR <<"_END");
clmakeblastdb $buildno
=======================================================================

Official web site of this script is
https://www.fifthdimension.jp/products/claident/ .
To know script details, see above URL.

Copyright (C) 2011-2018  Akifumi S. Tanabe

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License along
with this program; if not, write to the Free Software Foundation, Inc.,
51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

_END
	# display usage if command line options were not specified
	unless (@ARGV) {
		&helpMessage();
	}
}

sub getOptions {
	# get arguments
	$inputfile = $ARGV[-2];
	$output = $ARGV[-1];
	for (my $i = 0; $i < scalar(@ARGV) - 2; $i ++) {
		if ($ARGV[$i] =~ /^-+n(?:egative)?gilist=(.+)$/i) {
			$ngilist = $1;
		}
		elsif ($ARGV[$i] =~ /^-+n(?:egative)?seqidlist=(.+)$/i) {
			$nseqidlist = $1;
		}
		elsif ($ARGV[$i] =~ /^-+n(?:egative)?gis?=(.+)$/i) {
			foreach my $ngi (split(/,/, $1)) {
				$ngilist{$ngi} = 1;
			}
		}
		elsif ($ARGV[$i] =~ /^-+n(?:egative)?seqids?=(.+)$/i) {
			foreach my $nseqid (split(/,/, $1)) {
				$nseqidlist{$nseqid} = 1;
			}
		}
		elsif ($ARGV[$i] =~ /^-+min(?:imum)?len(?:gth)?=(\d+)$/i) {
			$minlen = $1;
		}
		elsif ($ARGV[$i] =~ /^-+max(?:imum)?len(?:gth)?=(\d+)$/i) {
			$maxlen = $1;
		}
		elsif ($ARGV[$i] =~ /^-+(?:n|n(?:um)?threads?)=(\d+)$/i) {
			$numthreads = $1;
		}
		else {
			&errorMessage(__LINE__, "\"$ARGV[$i]\" is unknown option.");
		}
	}
}

sub checkVariables {
	while (glob("$output.*.*")) {
		if (/^$output\..+\.fasta$/) {
			&errorMessage(__LINE__, "Temporary file already exists.");
		}
		elsif (/^$output\..+/) {
			&errorMessage(__LINE__, "Output file already exists.");
		}
	}
	if (!$inputfile) {
		&errorMessage(__LINE__, "Input file is not given.");
	}
	if (!-e $inputfile) {
		&errorMessage(__LINE__, "Input file does not exist.");
	}
	# search blastn
	{
		my $pathto;
		if ($ENV{'CLAIDENTHOME'}) {
			$pathto = $ENV{'CLAIDENTHOME'};
		}
		else {
			my $temp;
			if (-e '.claident') {
				$temp = '.claident';
			}
			elsif (-e $ENV{'HOME'} . '/.claident') {
				$temp = $ENV{'HOME'} . '/.claident';
			}
			elsif (-e '/etc/claident/.claident') {
				$temp = '/etc/claident/.claident';
			}
			if ($temp) {
				my $filehandle;
				unless (open($filehandle, "< $temp")) {
					&errorMessage(__LINE__, "Cannot read \"$temp\".");
				}
				while (<$filehandle>) {
					if (/^\s*CLAIDENTHOME\s*=\s*(\S[^\r\n]*)/) {
						$pathto = $1;
						$pathto =~ s/\s+$//;
						last;
					}
				}
				close($filehandle);
			}
		}
		if ($pathto) {
			$pathto =~ s/^"(.+)"$/$1/;
			$pathto =~ s/\/$//;
			$pathto .= '/bin';
			if (!-e $pathto) {
				&errorMessage(__LINE__, "Cannot find \"$pathto\".");
			}
			$makeblastdb = "\"$pathto/makeblastdb\"";
			$blastdb_aliastool = "\"$pathto/blastdb_aliastool\"";
		}
		else {
			$makeblastdb = 'makeblastdb';
			$blastdb_aliastool = 'blastdb_aliastool';
		}
	}
}

sub readNegativeSeqIDList {
	if ($ngilist) {
		$filehandleinput1 = &readFile($ngilist);
		while (<$filehandleinput1>) {
			if (/^\s*(\d+)/) {
				$ngilist{$1} = 1;
			}
		}
		close($filehandleinput1);
	}
	elsif ($nseqidlist) {
		$filehandleinput1 = &readFile($nseqidlist);
		while (<$filehandleinput1>) {
			if (/^\s*(\d+)/) {
				$nseqidlist{$1} = 1;
			}
		}
		close($filehandleinput1);
	}
}

sub splitInputFile {
	print(STDERR "Running makeblastdb...\n");
	# make splitted files
	{
		my $child = 0;
		$| = 1;
		$? = 0;
		my $temptotal = 0;
		my $tempseq;
		my $tempseqlen = 0;
		my $tempnfile = 0;
		my $switch = 0;
		$filehandleoutput1 = &writeFile("$output.$tempnfile.fasta");
		$filehandleinput1 = &readFile($inputfile);
		while (<$filehandleinput1>) {
			if (/^>\s*(\S+)\s*/) {
				my $seqid = $1;
				if (exists($nseqidlist{$seqid}) || $seqid =~ /gi\|(\d+)/ && (exists($ngilist{$1}) || exists($nseqidlist{$1})) || $seqid =~ /(?:gb|emb|dbj|ref|lcl)\|([^\|]+)/ && exists($nseqidlist{$1})) {
					$switch = 0;
					next;
				}
				$switch = 1;
				if ($tempseq) {
					if ($minlen && $maxlen && $tempseqlen >= $minlen && $tempseqlen <= $maxlen || $minlen && $tempseqlen >= $minlen || $maxlen && $tempseqlen <= $maxlen || !defined($minlen) && !defined($maxlen)) {
						print($filehandleoutput1 $tempseq);
						$temptotal += $tempseqlen;
					}
					$tempseq = $_;
					$tempseqlen = 0;
				}
				if ($temptotal >= $maxsize) {
					close($filehandleoutput1);
					if (my $pid = fork()) {
						$child ++;
						if ($child == $numthreads) {
							if (wait == -1) {
								$child = 0;
							} else {
								$child --;
							}
						}
						if ($?) {
							&errorMessage(__LINE__);
						}
						$temptotal = 0;
						$tempnfile ++;
						$filehandleoutput1 = &writeFile("$output.$tempnfile.fasta");
						next;
					}
					else {
						&runMakeblastdb($tempnfile);
						exit;
					}
				}
			}
			elsif ($switch) {
				$tempseqlen += length($_) - 1;
				$tempseq .= $_;
			}
		}
		close($filehandleinput1);
		if ($tempseq) {
			if ($minlen && $maxlen && $tempseqlen >= $minlen && $tempseqlen <= $maxlen || $minlen && $tempseqlen >= $minlen || $maxlen && $tempseqlen <= $maxlen || !defined($minlen) && !defined($maxlen)) {
				print($filehandleoutput1 $tempseq);
				$temptotal += $tempseqlen;
			}
			close($filehandleoutput1);
			if ($temptotal) {
				if (my $pid = fork()) {
					$child ++;
					if ($child == $numthreads) {
						if (wait == -1) {
							$child = 0;
						} else {
							$child --;
						}
					}
					if ($?) {
						&errorMessage(__LINE__);
					}
				}
				else {
					&runMakeblastdb($tempnfile);
					exit;
				}
			}
			else {
				unlink("$output.$tempnfile.fasta");
			}
		}
		else {
			close($filehandleoutput1);
		}
	}
	# join
	while (wait != -1) {
		if ($?) {
			&errorMessage(__LINE__, 'Cannot run makeblastdb correctly.');
		}
	}
	print(STDERR "done.\n\n");
}

sub runMakeblastdb {
	my $tempnfile = shift(@_);
	print(STDERR "Running makeblastdb using $output.$tempnfile.fasta...\n");
	system("$makeblastdb$makeblastdboption -in $output.$tempnfile.fasta -out $output.$tempnfile -title $output.$tempnfile 2> $devnull");
	if (!-e "$output.$tempnfile.nsq" || -z "$output.$tempnfile.nsq") {
		&errorMessage(__LINE__, "Cannot run makeblastdb correctly.");
	}
	unlink("$output.$tempnfile.fasta");
}

sub makeNal {
	print(STDERR "Aggregating databases...\n");
	$filehandleoutput1 = &writeFile("$output.dblist");
	while (glob("$output.*.nsq")) {
		print($filehandleoutput1 $_);
	}
	close($filehandleoutput1);
	system("$blastdb_aliastool -dbtype nucl -dblist_file $output.dblist -out $output -title $output");
	unlink("$output.dblist");
	if (!-e "$output.nal" || -z "$output.nal") {
		&errorMessage(__LINE__, "Cannot run blastdb_aliastool correctly.");
	}
	print(STDERR "done.\n\n");
}

sub readFile {
	my $filehandle;
	my $filename = shift(@_);
	unless (open($filehandle, "< $filename")) {
		&errorMessage(__LINE__, "Cannot open \"$filename\".");
	}
	if ($filename =~ /\.gz$/i) {
		unless ($filehandle = new IO::Uncompress::Gunzip($filehandle)) {
			&errorMessage(__LINE__, "Cannot open \"$filename\".");
		}
	}
	elsif ($filename =~ /\.bz2$/i) {
		unless ($filehandle = new IO::Uncompress::Bunzip2($filehandle)) {
			&errorMessage(__LINE__, "Cannot open \"$filename\".");
		}
	}
	elsif ($filename =~ /\.xz$/i) {
		unless ($filehandle = new IO::Uncompress::UnXz($filehandle)) {
			&errorMessage(__LINE__, "Cannot open \"$filename\".");
		}
	}
	return($filehandle);
}

# error message
sub errorMessage {
	my $lineno = shift(@_);
	my $message = shift(@_);
	print(STDERR "ERROR!: line $lineno\n$message\n");
	print(STDERR "If you want to read help message, run this script without options.\n");
	exit(1);
}

sub helpMessage {
	print(STDERR <<"_END");
Usage
=====
clmakeblastdb options inputfile outputBLASTDB

Command line options
====================
--negativegilist=FILENAME
  Specify file name of negative GI list. (default: none)

--negativegi=GI(,GI..)
  Specify negative GIs.

--negativeseqidlist=FILENAME
  Specify file name of negative SeqID list. (default: none)

--negativeseqid=SeqID(,SeqID..)
  Specify negative SeqIDs.

--minlen=INTEGER
  Specify minimum length of sequence. (default: none)

--maxlen=INTEGER
  Specify maximum length of sequence. (default: none)

-n, --numthreads=INTEGER
  Specify the number of processes. (default: 1)

Acceptable input file formats
=============================
FASTA
_END
	exit;
}