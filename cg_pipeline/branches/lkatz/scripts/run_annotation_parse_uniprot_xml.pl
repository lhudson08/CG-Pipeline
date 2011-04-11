#!/usr/bin/env perl

# Parse uniprot XML file and output DB3 file with concise information that we need.
# This file is run during installation
# Author: Andrey Kislyuk
# Modifications: Lee Katz, Jay Humphrey

use strict;
use warnings;
use FindBin;
use lib "$FindBin::RealBin/../lib";
$ENV{PATH} = "$FindBin::RealBin:".$ENV{PATH};
use AKUtils qw(logmsg);
use File::Basename;

# debugging
use Data::Dumper;
#use Smart::Comments;

# database IO
use XML::LibXML::Reader;
use BerkeleyDB;
use DBI; # SQLite

# threads
use threads;
use threads::shared;
use Thread::Queue;
my $numCpus=AKUtils::getNumCPUs();
#$numCpus=10; #debugging
my $stick : shared;

$0=fileparse($0);
exit(main());

sub main{
  die("Usage: $0 uniprot_sprot.xml uniprot_trembl.xml") if @ARGV < 1;
  my @infiles = @ARGV;
  for (@infiles) { die("File $_ not found") unless -f $_; }

my (%uniprot_h,%uniprot_evidence_h); #LK
my $recordCount=0; #LK

  #createDatabase();
  
  # set up the queue and threads that read from the queue
  my $queue=Thread::Queue->new;
  my @thr;
  for my $t(0 .. $numCpus-1){
    push(@thr,threads->create(\&xmlReaderThread,$queue));
  }

  # read the XML, send data to the queue for the threads
  # TODO (maybe) multithread reading the XML
  INFILE:
  foreach my $infile (@infiles) {
    logmsg "Processing XML in file $infile with $numCpus CPUs";
    my $file_size = (stat $infile)[7];
    my $reader = new XML::LibXML::Reader(location => $infile) or die "cannot read $infile\n";
    my $i=0;
    # read the XML, paying close attention to the elements we want
    while ($reader->read) {
      # this is an element we want
      if ($reader->name eq 'entry' and $reader->nodeType != XML_READER_TYPE_END_ELEMENT) {
        $i++; $recordCount++; 
        # check in every 1000 records
        if($i % 1000 == 0){
          # status update
          my $status="$infile: ["
            .int(100*$reader->byteConsumed/$file_size)
            ."%] Processed $i records"
            ;

          # queue update
          if($i % 10000 == 0){
            $status.=" (jobs still pending: ".$queue->pending.", $numCpus cpus)";
            # wait if the queue is really large
            sleep(1) while($queue->pending>10000);
          }
          logmsg($status);

          # debug
          if($i>10000){ logmsg "DEBUGGING, skipping rest of the file";next INFILE;}
        }
        # enqueue the data we want to look at; one thread will dequeue the data
        $queue->enqueue($reader->readOuterXml);
        $reader->next; # skip subtree
      }
    }
    NEXT_INFILE:
    logmsg "Processed $i records, done with file $infile";
    $reader->close; # free up any reader resources
  }
  # let the threads finish off the queue
  logmsg "Processed $recordCount records, done";
  while(my $numPending=$queue->pending){
    logmsg "$numPending more left..";
    sleep 1;
  }

  my($db,$db_evidence)=createDatabase("cgpipeline");
  logmsg("Creating final database");
  # terminate the threads
  $queue->enqueue(undef) for(0..$numCpus-1); # send TERM signals
  for(my $t=0;$t<$numCpus;$t++){
    logmsg("Joining tmp database ".$thr[$t]->tid);
    my ($tmpDb,$tmpDb_evidence)=$thr[$t]->join;
    logmsg("Merging uniprot db");
    print Dumper $tmpDb;
    foreach my $accession(keys %$tmpDb){
      print ".";
      $$db{$accession}=$$tmpDb{$accession};
    }
    logmsg("Merging evidence db");
    foreach my $accession(keys(%$tmpDb_evidence)){
      $$db_evidence{$accession}=$$tmpDb_evidence{$accession};
    }
  }

  # close off the database
  closeDatabase("cgpipeline");
  logmsg "All records are now in the DB!";

  return 0;
}

# This is the subroutine of each thread.
# It waits for a queued item and then processes it
sub xmlReaderThread{
  my($queue)=@_;
  my $basename="tmp".threads->tid();
  my($db,$db_evidence)=createDatabase($basename);
  my($tmpDb,$tmpDb_evidence);
  my $numTempRecords=0;
  while(my $data=$queue->dequeue){
    my($accession,$uniprot,$evidence)=processUniprotXMLEntry($data);
    $$tmpDb{$accession}=join("|",@$uniprot);
    for my $line(@$evidence){
      $$tmpDb_evidence{accession}=$line; # isn't this overwriting the previous value though???
    }
    $numTempRecords++;

    # clear the temp hash if it gets past a certain point
    # and write them to the db
    if($numTempRecords>1000){
      lock($stick);
      logmsg("Writing to DB $basename");
      while( my($accession,$value)=each(%$db) ){
        $$db{$accession}=$$tmpDb{$accession}
      }
      while( my($accession,$value)=each(%$tmpDb_evidence) ){
        $$db_evidence{$accession}=$$tmpDb_evidence{$accession}   
      }
      $tmpDb_evidence={};
      $tmpDb={};
      $numTempRecords=0;
    }
  }
  # TODO write the tmpDb to the DB once more before returning

  return ($db,$db_evidence);
}

# processes an XML entry
sub processUniprotXMLEntry($) {
	my ($xml_string) = @_;
	my $parser = XML::LibXML->new();
	my $entry = $parser->parse_string($xml_string);

  # initialize all %info keys
	my %info;
  my @infoKeys=qw(accession name dataset proteinName proteinType geneType geneName dbRefId);

	$info{accession} = $entry->getElementsByTagName('accession')->[0]->firstChild->nodeValue;

	$info{dataset} = $entry->getElementsByTagName('entry')->[0]->attributes->getNamedItem('dataset')->nodeValue;
	$info{name} = $entry->getElementsByTagName('name')->[0]->firstChild->nodeValue;
	# NB: the field names don't reflect the real meaning
	if (my $p = $entry->getElementsByTagName('protein')) {
		if ($p->[0]->childNodes and $p->[0]->childNodes->[1]->childNodes) {
			$info{proteinName} = $p->[0]->childNodes->[1]->childNodes->[1]->firstChild->nodeValue;
		}
	}
	if (my $pe_tag = $entry->getElementsByTagName('proteinExistence')) {
		$info{proteinType} = $pe_tag->[0]->attributes->getNamedItem('type')->nodeValue;
	}

	if (my @genes = $entry->getElementsByTagName('gene')) {
		my $name_tags = $genes[0]->getElementsByTagName('name');
		$info{geneName} = $name_tags->[0]->firstChild->nodeValue;
		$info{geneType} = $name_tags->[0]->attributes->getNamedItem('type')->nodeValue;
	} elsif (my @gene_location_list = $entry->getElementsByTagName('geneLocation')) {
		if (my $name_tags = $gene_location_list[0]->getElementsByTagName('name')) {
			if ($name_tags->[0]->firstChild) {
				$info{geneName} = $name_tags->[0]->firstChild->nodeValue;
				if ($info{geneType} = $name_tags->[0]->attributes->getNamedItem('type')) {
					$info{geneType} = $name_tags->[0]->attributes->getNamedItem('type')->nodeValue;
				}
			}
		}
	}

	my @db_refs;
	foreach my $db_ref ($entry->getElementsByTagName('dbReference')) {
		my $db_ref_type = $db_ref->attributes->getNamedItem('type')->nodeValue;
		my $db_ref_id = $db_ref->attributes->getNamedItem('id')->nodeValue;

		$info{dbRefId} = $db_ref_id if $db_ref_type eq 'GeneId';

		my @property_list = $db_ref->getElementsByTagName('property');
		next unless @property_list;
		my $property_type = $property_list[0]->attributes->getNamedItem('type')->nodeValue;
		next if $property_type ne 'entry name';
		
		my $db_ref_name = $property_list[0]->attributes->getNamedItem('value')->nodeValue;

		push(@db_refs, {accession => $info{accession},
						dbRefId => $db_ref_id,
						dbRefType => $db_ref_type,
						dbRefName => $db_ref_name});
	}

  # clear out any undef values
  $info{$_}||="" for @infoKeys;

  # escape any pipes
	s/\|/\\|/g for values(%info);

  # prep the records for the database; put the keys in the right order
  my @line; # for %uniprot_h
  my @line_evidence; # for uniprot_evidence_h
  push(@line, $info{$_}) for @infoKeys;
  foreach my $ref (@db_refs) {
    s/\|/\\|/g for values(%$ref);
    my @line; 
    push(@line, $$ref{$_}) for qw(accession dbRefId dbRefType dbRefName);
    push(@line_evidence,join('|',@line));
  }

  return ($info{accession},\@line,\@line_evidence);
}

# create a BerkeleyDB::Hash database
sub createDatabase{
  lock($stick); # one db created at a time
  my ($basename)=@_;
  my ($dbfile, $evidence_dbfile) = ("$basename.db3", "$basename.evidence.db3");
  unlink $dbfile while(-f $dbfile);
  unlink $evidence_dbfile while(-f $evidence_dbfile);

  my(%uniprot_h,%uniprot_evidence_h);
  tie(%uniprot_h, "BerkeleyDB::Hash", -Filename => $dbfile, -Flags => DB_CREATE, -Property => DB_DUP)
    or die "Cannot open file $dbfile: $! $BerkeleyDB::Error\n";
  tie(%uniprot_evidence_h, "BerkeleyDB::Hash", -Filename => $evidence_dbfile, -Flags => DB_CREATE, -Property => DB_DUP)
    or die "Cannot open file $evidence_dbfile: $! $BerkeleyDB::Error\n";
  return(\%uniprot_h,\%uniprot_evidence_h);
}
sub closeDatabase{
  lock($stick); # one db closed at a time
  my($uniprot_h,$uniprot_evidence_h)=@_;
  untie %$uniprot_h;
  untie %$uniprot_evidence_h;
}
