#!/usr/bin/env perl

# run-assembly: Perform standard assembly protocol operations on 454 pyrosequenced flowgram file(s)
# Author: Andrey Kislyuk (kislyuk@gatech.edu)

package PipelineRunner;
my ($VERSION) = ('$Id: $' =~ /,v\s+(\d+\S+)/o);

my $settings = {
	appname => 'cgpipeline',
};
my $stats;

use strict;
use FindBin;
use lib "$FindBin::RealBin/../lib";
$ENV{PATH} = "$FindBin::RealBin:".$ENV{PATH};
use AKUtils qw(logmsg);

use Getopt::Long;
use File::Temp ('tempdir');
use File::Path;
use File::Spec;
use File::Copy;
use File::Basename;
use List::Util qw(min max sum shuffle);
use CGPipelineUtils;
use Data::Dumper;

$0 = fileparse($0);
local $SIG{'__DIE__'} = sub { my $e = $_[0]; $e =~ s/(at [^\s]+? line \d+\.$)/\nStopped $1/; die("$0: ".(caller(1))[3].": ".$e); };
sub logmsg {my $FH = $FSFind::LOG || *STDOUT; print $FH "$0: ".(caller(1))[3].": @_\n";}

exit(main());

sub main() {
	$settings = AKUtils::loadConfig($settings);

	die("Usage: $0 input.sff [, input2.sff, ...] [-R references.mfa] [-C workdir]") if @ARGV < 1;

	my @cmd_options = ('ChangeDir=s', 'Reference=s@', 'keep', 'tempdir=s', 'output=s');
	GetOptions($settings, @cmd_options) or die;

	$$settings{outfile} = $$settings{output};
	$$settings{outfile} ||= "$0.out.fasta";
	$$settings{outfile} = File::Spec->rel2abs($$settings{outfile});
	open(FH, '>', $$settings{outfile}) or die("Error writing to output file $$settings{outfile}");
	close FH;
	logmsg "Output file is " . $$settings{outfile} . "\n";

	my @ref_files = @{$$settings{Reference}} if defined $$settings{Reference};
	logmsg "No reference files supplied. Reverting to assembly mode" unless @ref_files;

	my @input_files = @ARGV;

	$$settings{tempdir} ||= tempdir(File::Spec->tmpdir()."/$0.$$.XXXXX", CLEANUP => !($$settings{keep}));
	logmsg "Temporary directory is $$settings{tempdir}";

	foreach my $file (@input_files, @ref_files) {
		$file = File::Spec->rel2abs($file);
		die("Input or reference file $file not found") unless -f $file;
	}

  my $fastaqualfiles = sff2fastaqual(\@input_files, $settings);

	my $final_seqs;

	if (@ref_files) {
    # TODO multithread reference assemblies
		my $newbler_basename = runNewblerMapping(\@input_files, \@ref_files, $settings);

		my $amos_basename = runAMOSMapping($fastaqualfiles, \@ref_files, $settings);

		my $combined_filename = combineNewblerAMOS($newbler_basename, $amos_basename, $settings);

		$final_seqs = AKUtils::readMfa($combined_filename);
	} else {
    
    # TODO multithread assemblies
		my $newbler_basename = runNewblerAssembly(\@input_files, $settings);

    my $velvet_basename = runVelvetAssembly($fastaqualfiles,$settings);

    my $combined_filename=combineNewblerVelvetDeNovo($newbler_basename,$velvet_basename,$settings);

		# TODO: reprocess repeat or long singleton reads
    # repeating the process might be moot if we use reconciliator -LK
		$final_seqs = AKUtils::readMfa("$combined_filename");
	}
	
	$$settings{min_out_contig_length} = 500;

	foreach my $seq (keys %$final_seqs) {
		delete $$final_seqs{$seq} if length($$final_seqs{$seq}) < $$settings{min_out_contig_length};
	}
	AKUtils::printSeqsToFile($final_seqs, $$settings{outfile}, {order_seqs_by_name => 1});

	#copy($combined_filename, $$settings{outfile}) or die("Error writing to output file $$settings{outfile}");
	logmsg "Output is in $$settings{outfile}";

	if ($$settings{keep}) {
		my ($out_filename, $out_dirname) = fileparse($$settings{outfile});
		logmsg "Saving assembly working directory $$settings{tempdir} to $out_dirname";
		move($$settings{tempdir}, $out_dirname) or die "Error moving output directory $$settings{tempdir} to $out_dirname: $!";
	}

	return 0;
}

# creates qual and sequence fasta files for an SFF file (basecalling)
sub sff2fastaqual($$) {
	my ($sff_files, $settings) = @_;
	my @fastaqualfiles;
	foreach my $input_file (@$sff_files) {
		my ($sff_file, $sff_dir) = fileparse($input_file);
		my $invoke_string = "sffinfo -seq '$sff_dir/$sff_file' > '$$settings{tempdir}/$sff_file.fasta'";
		logmsg "Running $invoke_string";
		system($invoke_string); die if $?;
		$invoke_string = "sffinfo -qual '$sff_dir/$sff_file' > '$$settings{tempdir}/$sff_file.qual'";
		logmsg "Running $invoke_string";
		system($invoke_string); die if $?;
		push(@fastaqualfiles, ["$$settings{tempdir}/$sff_file.fasta", "$$settings{tempdir}/$sff_file.qual"]);
	}
	return \@fastaqualfiles;
}

sub runNewblerMapping($$$) {
	my ($input_files, $ref_files, $settings) = @_;
	my $run_name = "$$settings{tempdir}/P__runMapping";
	logmsg "Executing Newbler mapping project $run_name";

	system("newMapping '$run_name'"); die if $?;
	foreach my $ref_file (@$ref_files) {
		system("setRef '$run_name' '$ref_file'"); die if $?;
	}
	foreach my $sff_file (@$input_files) {
		system("addRun '$run_name' '$sff_file'"); die if $?;
	}
#sed -i -e 's|\(<overlapMinMatchLength>\)40\(</overlapMinMatchLength>\)|\125\2|' \
#               -e 's|\(<overlapMinMatchIdentity>\)90\(</overlapMinMatchIdentity>\)|\175\2|' \
#               $runName/mapping/454MappingProject.xml
	system("runProject '$run_name'"); die if $?;
	return $run_name;
}

sub runNewblerAssembly($$) {
	my ($input_files, $settings) = @_;
	my $run_name = "$$settings{tempdir}/P__runAssembly";
  # logmsg "Skipping newbler assembly for testing purposes";  return $run_name; #debugging
	logmsg "Executing Newbler assembly project $run_name";

	system("newAssembly '$run_name'"); die if $?;
	foreach my $sff_file (@$input_files) {
		system("addRun '$run_name' '$sff_file'"); die if $?;
	}
#sed -i -e 's|\(<overlapMinMatchLength>\)40\(</overlapMinMatchLength>\)|\125\2|' \
#               -e 's|\(<overlapMinMatchIdentity>\)90\(</overlapMinMatchIdentity>\)|\175\2|' \
#               $runName/mapping/454MappingProject.xml
	system("runProject '$run_name'"); die if $?;
	return $run_name;
}

# TODO multithread different hash lengths of Velveth
# Heuristic: use hash lengths according to the formula in the Velvet manual, keeping in mind that 20x coverage is the goal. No more no less.
# Use assembly stats to return the best assembly.
# Ck=C*(L-k+1)/L, k is hash length (odd number, <32bp), L is read length, C is nucleotide coverage, Ck is k-mer coverage (20>Ck>10)
sub runVelvetAssembly($$){
  my($fastaqualfiles,$settings)=@_;
  my $run_name = "$$settings{tempdir}/velvetAssembly";
  #logmsg "Skipping Velvet assembly"; return $run_name; # debugging
  mkdir($run_name) if(!-d $run_name);
  logmsg "Executing Velvet assembly $run_name";
  my $velvetPrefix=File::Spec->abs2rel("$run_name/auto");
  my $command="VelvetOptimiser.pl -a -v -p $velvetPrefix ";
  $command.="-f '";
  foreach my $fqFiles (@$fastaqualfiles){
    #TODO detect the chemistry of each run and treat them differently (454, Illumina, etc)
    #see if the reads are mate pairs (454)
    my $isMatePairs=0;
    #TODO find out if it's mate pairs somehow from Newbler, since linkers themselves aren't always standard
    my $numLinkers=`grep -c 'GTTGGAACCGAAAGGGTTTGAATTCAAACCCTTTCGGTTCCAAC\\|TCGTATAACTTCGTATAATGTATGCTATACGAAGTTATTACG' $$fqFiles[0]`;
    if($numLinkers>1000){ # arbitrary threshold; should be >25% of the reads according to the Newbler manual
      $isMatePairs=1;
    }
    #TODO remove reads with an overall bad quality (about <20)
    #TODO examine reads to see if the file overall belongs in "long" "short" etc: might just filter based on chemistry
    my $readLength="long"; # per velvet docs
    my $ins_length=0;
    if($isMatePairs){
      $readLength="longPaired";
    }
    $command.="-$readLength $$fqFiles[0] ";
  }
  $command.="' ";
  logmsg "$command";
  system($command); die if $?;
  system("amos2ace $run_name/velvet_asm.afg"); die if $?; # make an ace file too

  #TODO create dummy qual file (phred qual for each base is probably about 60-65). Or, if Velvet outputs it in the future, add in the qual parameter.
  #TODO incorporate ins_length parameter somehow (2500 for 454)

  # cleanup
  my @velvetTempDir=glob("$velvetPrefix*"); # find the output directory
  system("mv $velvetTempDir[0]/* $run_name/"); # move the output directory contents to the actual directory
  system("rmdir $velvetTempDir[0]");

  return $run_name;
}

sub runAMOSMapping($$$) {
	my ($input_files, $ref_files, $settings) = @_;
	my $run_name = "$$settings{tempdir}/amos_mapping";
	logmsg "Executing AMOS mapping project $run_name";

	my @afg_files;
	foreach my $input_file_pair (@$input_files) {
		my ($input_fasta_file, $input_qual_file) = @$input_file_pair;
		system("toAmos -s '$input_fasta_file' -q '$input_qual_file' -o '$input_fasta_file.afg'"); die if $?;
		push(@afg_files, "$input_fasta_file.afg");
	}

	my $invoke_string = "AMOScmp";
	$invoke_string .= " -D TGT='$_'" for @afg_files;
	$invoke_string .= " -D REF='$_'" for @$ref_files;
	$invoke_string .= " $run_name";
	logmsg "Running $invoke_string";
	system($invoke_string); die if $?;

	return $run_name;
}

# combine newbler and velvet de novo assemblies
sub combineNewblerVelvetDeNovo($$$) {
	my ($newbler_basename, $velvet_basename, $settings) = @_;
	logmsg "Running Newbler-Velvet combining on $newbler_basename, $velvet_basename";

  # get accessions for the reads that won't be in the final assembly: Outlier Repeat Singleton TooShort
	my (%outlier_reads, %repeat_reads,%singleton_reads,%tooShort_reads,$command);
	open(IN, '<', "$newbler_basename/assembly/454ReadStatus.txt") or die("Could not open 454ReadStatus.txt file\n");
	while (<IN>) {
		chomp;
		my ($read_id, $status) = split /\s+/;
		$outlier_reads{$read_id} = 1 if $status eq 'Outlier'; # problematic reads (chimeras, contamination, etc)
		$repeat_reads{$read_id} = 1 if $status eq 'Repeat'; # probably from repeat region, thus excluded from assembly
		$singleton_reads{$read_id} = 1 if $status eq 'Singleton'; # no overlaps found
		$tooShort_reads{$read_id} = 1 if $status eq 'TooShort'; # shorter than 50bp, or <15bp with paired end reads
	}
	close IN;

  # print out the accessions to file
	open(OUT, '>', "$$settings{tempdir}/newbler_outlier_acc") or die;
	print OUT "$_\n" for keys %outlier_reads;
	close OUT;
	open(OUT, '>', "$$settings{tempdir}/newbler_repeat_acc") or die;
	print OUT "$_\n" for keys %repeat_reads;
	close OUT;
	open(OUT, '>', "$$settings{tempdir}/newbler_singleton_acc") or die;
	print OUT "$_\n" for keys %singleton_reads;
	close OUT;
	open(OUT, '>', "$$settings{tempdir}/newbler_tooShort_acc") or die;
	print OUT "$_\n" for keys %tooShort_reads;
	close OUT;

  # create SFFs of the accessions not included in the assembly
	system("sfffile -i '$$settings{tempdir}/newbler_outlier_acc' -o '$$settings{tempdir}/newbler_outlier.sff' '$newbler_basename'/sff/*.sff");
	die if $?;
	my $outlier_fastaqual = sff2fastaqual(["$$settings{tempdir}/newbler_outlier.sff"], $settings);
	system("sfffile -i '$$settings{tempdir}/newbler_repeat_acc' -o '$$settings{tempdir}/newbler_repeat.sff' '$newbler_basename'/sff/*.sff");
	die if $?;
	my $repeat_fastaqual = sff2fastaqual(["$$settings{tempdir}/newbler_repeat.sff"], $settings);
	system("sfffile -i '$$settings{tempdir}/newbler_singleton_acc' -o '$$settings{tempdir}/newbler_singleton.sff' '$newbler_basename'/sff/*.sff");
	die if $?;
	my $singleton_fastaqual = sff2fastaqual(["$$settings{tempdir}/newbler_singleton.sff"], $settings);
	system("sfffile -i '$$settings{tempdir}/newbler_tooShort_acc' -o '$$settings{tempdir}/newbler_tooShort.sff' '$newbler_basename'/sff/*.sff");
	die if $?;
	my $tooShort_fastaqual = sff2fastaqual(["$$settings{tempdir}/newbler_tooShort.sff"], $settings);

  # choose either Newbler contigs or scaffolds if they exist
  my $newblerAssembly="$newbler_basename/assembly/454AllContigs.fna";
  $newblerAssembly="$newbler_basename/assembly/454Scaffolds.fna" if(-s "$newbler_basename/assembly/454Scaffolds.fna" > 0);
  my $velvetAssembly="$velvet_basename/contigs.fa";
  # begin the combining
	my $newbler_contigs = count_contigs($newblerAssembly); 
	my $velvet_contigs = count_contigs($velvetAssembly);
	my $combined_fasta_file = "$$settings{tempdir}/combined_in.fasta";
	my $numcontigs=0;
  if($velvet_contigs>0 && $newbler_contigs>0){ # can't have 0 contigs
    if($newbler_contigs < $velvet_contigs){
      system("cat '$newblerAssembly' '$velvetAssembly' '$$singleton_fastaqual[0]->[0]' > $combined_fasta_file");
      $numcontigs=$newbler_contigs;
      logmsg("Newbler de novo assembly ($newbler_contigs contigs) selected as reference for Minimus2");
    }
    else{
      system("cat '$velvetAssembly' '$newblerAssembly' '$$singleton_fastaqual[0]->[0]' > $combined_fasta_file");
      $numcontigs=$velvet_contigs;
      logmsg("Velvet de novo assembly ($velvet_contigs contigs) selected as reference for Minimus2");
    }
    die if $?;
    system("toAmos -s '$combined_fasta_file' -o '$$settings{tempdir}/minimus.combined.afg'");
    system("minimus2 -D REFCOUNT=$numcontigs '$$settings{tempdir}/minimus.combined'");
  }
  # if only one has contigs in its assembly, use the assembly metrics to automatically put the right assembly into the output file
  else{
    #system("cat '$newblerAssembly' '$$singleton_fastaqual[0]->[0]' > $combined_fasta_file");
    #$numcontigs=$newbler_contigs;
    #logmsg("Attempting to use Minimus2 to assemble singletons");
    system("run_assembly_chooseBest.pl $velvetAssembly $newblerAssembly --output $$settings{tempdir}/minimus.combined.fasta");
  }

	return "$$settings{tempdir}/minimus.combined.fasta";
}
# combine reference
sub combineNewblerAMOS($$$) {
	my ($newbler_basename, $amos_basename, $settings) = @_;
	logmsg "Running Newbler-AMOS combining on $newbler_basename, $amos_basename";

	my (%unmapped_reads, %repeat_reads);
	open(IN, '<', "$newbler_basename/mapping/454ReadStatus.txt") or die;
	while (<IN>) {
		chomp;
		my ($read_id, $status) = split /\s+/;
		$unmapped_reads{$read_id} = 1 if $status eq 'Unmapped';
		$repeat_reads{$read_id} = 1 if $status eq 'Repeat';
	}
	close IN;

	open(OUT, '>', "$$settings{tempdir}/newbler_unmapped_acc") or die;
	print OUT "$_\n" for keys %unmapped_reads;
	close OUT;
	open(OUT, '>', "$$settings{tempdir}/newbler_repeat_acc") or die;
	print OUT "$_\n" for keys %repeat_reads;
	close OUT;

	system("sfffile -i '$$settings{tempdir}/newbler_unmapped_acc' -o '$$settings{tempdir}/newbler_unmapped.sff' '$newbler_basename'/sff/*.sff");
	die if $?;
	my $unmapped_fastaqual = sff2fastaqual(["$$settings{tempdir}/newbler_unmapped.sff"], $settings);
	system("sfffile -i '$$settings{tempdir}/newbler_repeat_acc' -o '$$settings{tempdir}/newbler_repeat.sff' '$newbler_basename'/sff/*.sff");
	die if $?;
	my $repeat_fastaqual = sff2fastaqual(["$$settings{tempdir}/newbler_repeat.sff"], $settings);

	my $newbler_contigs = count_contigs("$newbler_basename/mapping/454AllContigs.fna");
	my $amos_contigs = count_contigs("$amos_basename.fasta");
	my $combined_fasta_file = "$$settings{tempdir}/combined_in.fasta";
	my $numcontigs=0;
	if($newbler_contigs < $amos_contigs){
		system("cat '$newbler_basename/mapping/454AllContigs.fna' '$amos_basename.fasta' '$$unmapped_fastaqual[0]->[0]' > $combined_fasta_file");
		$numcontigs=$newbler_contigs;
		logmsg("Newbler reference assembly selected as reference for minimus2");
	}
	else{
		system("cat '$amos_basename.fasta' '$newbler_basename/mapping/454AllContigs.fna' '$$unmapped_fastaqual[0]->[0]' > $combined_fasta_file");
		$numcontigs=$amos_contigs;
		logmsg("AMOScmp reference assembly selected as reference for minimus2");
	}
	die if $?;
	system("toAmos -s '$combined_fasta_file' -o '$$settings{tempdir}/minimus.combined.afg'");
	system("minimus2 -D REFCOUNT=$numcontigs '$$settings{tempdir}/minimus.combined'");

	return "$$settings{tempdir}/minimus.combined.fasta";
}
# TODO use run_assembly_metrics.pl instead to streamline
sub count_contigs{
	my $file=shift;
	open(FH,"<$file")or die "Could not find $file because $!";
	my @lines=<FH>;
	close(FH);
	my @contigs=grep /^>/,@lines;
	return scalar @contigs;
}
