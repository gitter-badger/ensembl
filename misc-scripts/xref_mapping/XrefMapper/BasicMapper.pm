package XrefMapper::BasicMapper;

use strict;
use Cwd;
use DBI;
use File::Basename;
use IPC::Open3;
use Bio::EnsEMBL::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Translation;
use XrefMapper::db;

use vars '@ISA';

@ISA = qw{ XrefMapper::db };


=head1 NAME

XrefMapper::BasicMapper

=head1 DESCIPTION

This is the basic mapper routine. It will create the necessary fasta files for
both the xref and ensembl sequences. These will then be matched using exonerate
and the results written to another file. By creating a <species>.pm file and 
inheriting from this base class different matching routines, parameters, data 
sets etc can be set.

=head1 CONTACT

Post questions to the EnsEMBL development list ensembl-dev@ebi.ac.uk


=cut

# Hashes to hold method-specific thresholds
my %method_query_threshold;
my %method_target_threshold;

# Various useful variables.
my %translation_to_transcript;
my %transcript_to_translation;
my %genes_to_transcripts;
my %xref_to_source;
my %object_xref_mappings;
my %object_xref_identities;
my %xref_descriptions;
my %xref_accessions;
my %source_to_external_db;
my %xrefs_written;
my %object_xrefs_written;

my $core_dbi;
my $xref_dbi;

=head2 dump_seqs

  Arg[1]: xref object which holds info needed for the dump of xref

  Description: Dumps out the files for the mapping. Xref object should hold
              the value of the databases and source to be used.
  Returntype : none
  Exceptions : will die if species not known or an error occurs while
             : trying to write to files. 
  Caller     : general
 
=cut
 


sub dump_seqs{

  my ($self, $location) = @_;

  # initialise DB connections
  $core_dbi = $self->dbi();
  $xref_dbi = $self->xref()->dbi();

  $self->dump_xref();
  $self->dump_ensembl($location);

}



=head2 build_list_and_map

  Arg[1]: xref object which holds info on method and files.

  Description: runs the mapping of the list of files with species methods
  Returntype : none
  Exceptions : none
  Caller     : general

=cut

sub build_list_and_map {

  my ($self) = @_;

  my @list=();

  my $i = 0;
  foreach my $method (@{$self->method()}){
    my @dna=();
    push @dna, $method;
    push @dna, $self->xref->dir."/xref_".$i."_dna.fasta";
    push @dna, $self->ensembl_dna_file();
    push @list, \@dna;
    my @pep=();
    push @pep, $method;
    push @pep, $self->xref->dir."/xref_".$i."_peptide.fasta";
    push @pep, $self->ensembl_protein_file();
    push @list, \@pep;
    $i++;
  }

  $self->run_mapping(\@list);

}


=head2 get_species_id_from_species_name

  Arg[1]: species name

  Description: get the species_id from the database for the named database.
  Example    : my $id = get_species_id_from_species_name('homo_sapiens');
  Returntype : int (species_id)
  Exceptions : will die if species does not exist in given xref database.
  Caller     : general

=cut

sub get_species_id_from_species_name{
  my ($xref,$species) = @_;

  my $sql = "select species_id from species where name = '".$species."'";
  my $sth = $xref_dbi->prepare($sql);
  $sth->execute();
  my @row = $sth->fetchrow_array();
  my $species_id;
  if (defined @row) {
    $species_id = $row[0];
  } else {
    print STDERR "Couldn't get ID for species ".$species."\n";
    print STDERR "It must be one of :-\n";
    $sql = "select name from species";
    $sth = $xref_dbi->prepare($sql);
    $sth->execute();
    while(my @row = $sth->fetchrow_array()){
      print STDERR $row[0]."\n";
    }
    die("Please try again :-)\n");
  }
  $sth->finish();

  return $species_id;
}


=head2 get_set_lists

  Description: specifies the list of databases and source to be used in the
             : generation of one or more data sets.
  Returntype : list of lists
  Example    : my @lists =@{$self->get_set_lists()};
  Exceptions : none
  Caller     : dump_xref

=cut

sub get_set_lists{
  my ($self) = @_;

  #  return [["ExonerateGappedBest1", ["homo_sapiens","Uniprot/SWISSPROT"]]];

#  return [["method1",["homo_sapiens","RefSeq"],["homo_sapiens","UniProtSwissProt"]],
#	  ["method2",[$self->species,"*"]],
#	  ["method3",["*","*"]]];

  return [["ExonerateGappedBest1", ["homo_sapiens","*"], ["mus_musculus", "*"]]];

}

=head2 get_source_id_from_source_name

  Arg[1]: source name

  Description: get the source_id from the database for the named source.
  Example    : my $id = get_source_id_from_source_name('RefSeq');
  Returntype : int (source_id)
  Exceptions : will die if source does not exist in given xref database.
  Caller     : general

=cut

sub get_source_id_from_source_name{
  my ($xref, $source) = @_;
  my $source_id;
  
  my $sql = "select source_id from source where name = '".$source."'";
  my $sth = $xref_dbi->prepare($sql);
  $sth->execute();
  my @row = $sth->fetchrow_array();
  if (defined $row[0] and $row[0] ne '') {
    $source_id = $row[0];
#    print $source."\t*".$row[0]."*\n";
  } else {
    print STDERR "Couldn't get ID for source ".$source."\n";
    print STDERR "It must be one of :-\n";
    $sql = "select name from source";
    $sth = $xref_dbi->prepare($sql);
    $sth->execute();
    while(my @row = $sth->fetchrow_array()){
      print STDERR $row[0]."\n";
    }
    die("Please try again :-)\n");
  }
  $sth->finish();

  return $source_id;
} 


=head2 dump_xref

  Arg[1]: xref object which holds info on method and files.

  Description: Dumps the Xref data as fasta file(s)
  Returntype : none
  Exceptions : none
  Caller     : dump_seqs

=cut

sub dump_xref{
  my ($self) = @_;
  
  my $xref =$self->xref();
  if(!defined($xref->dir())){
    if(defined($self->dir)){
      $xref->species($self->dir);
    }
    else{
      $xref->dir(".");
    }
  }
  
  my @method=();
  
  my @lists =@{$self->get_set_lists()};
  
  my $i=0;
  if(defined($self->dumpcheck())){
    my $skip = 1;
    foreach my $list (@lists){
      if(!-e $xref->dir()."/xref_".$i."_dna.fasta"){ 
	$skip = 0;
      }
      if(!-e $xref->dir()."/xref_".$i."_peptide.fasta"){ 
	$skip = 0;
      }
      $i++;
    }
    if($skip){
      my $k = 0;
      foreach my $list (@lists){
	$method[$k++] = shift @$list;
      }
      $self->method(\@method);
      return;
    }
  }

  $i=0;
  foreach my $list (@lists){
#    print "method->".@$list[0]."\n";
    $method[$i] = shift @$list;
    my $j = 0;
    my @source_id=();
    my @species_id=();
    foreach my $element (@$list){
      while(my $species = shift(@$element)){
	#	print $j.")\t".$species."\n";
	if($species ne "*"){
	  $species_id[$j] = get_species_id_from_species_name($xref,$species);
	}
	else{
	  $species_id[$j] = -1;
	}
	my $source = shift(@$element);
	if($source ne "*"){
	  $source_id[$j] = get_source_id_from_source_name($xref,$source);
	}
	else{
	  $source_id[$j] = -1;
	}
#	print $j."\t".$source. "\t".$source_id[$j] ."\n";
#	print $j."\t".$species."\t".$species_id[$j]."\n";
	$j++;
      }
    }
    #method data fully defined now
    $self->dump_subset($xref,\@species_id,\@source_id,$i);    
    $i++;
  }
  
  $self->method(\@method);

  return;
  
}

=head2 dump_subset

  Arg[1]: xref object which holds info on files.
  Arg[2]: list of species to use.
  Arg[3]: list of sources to use.
  Arg[4]: index to be used in file creation.
  
  Description: Dumps the Xref data for one set of species/databases
  Returntype : none
  Exceptions : none
  Caller     : dump_xref

=cut


sub dump_subset{

  my ($self,$xref,$rspecies_id,$rsource_id,$index) = @_;

  # generate or condition list for species and sources
  my $final_clause;
  my $use_all = 0;
  my @or_list;
  for (my $j = 0; $j < scalar(@$rspecies_id); $j++){
    my @condition;
    if($$rspecies_id[$j] > 0){
      push @condition, "x.species_id=" . $$rspecies_id[$j];
    }
    if($$rsource_id[$j] > 0){
      push @condition, "x.source_id=" . $$rsource_id[$j];
    }

    # note if both source and species are * (-1) there's no need for a final clause

    if ( !@condition ) {
      $use_all = 1;
      last;
    }

    push @or_list, join (" AND ", @condition);

  }

  $final_clause = " AND ((" . join(") OR (", @or_list) . "))" unless ($use_all) ;


  for my $sequence_type ('dna', 'peptide') {

    my $filename = $xref->dir() . "/xref_" . $index . "_" . $sequence_type . ".fasta";
    open(XREF_DUMP,">$filename") || die "Could not open $filename";

    my $sql = "SELECT p.xref_id, p.sequence, x.species_id , x.source_id ";
    $sql   .= "  FROM primary_xref p, xref x ";
    $sql   .= "  WHERE p.xref_id = x.xref_id AND ";
    $sql   .= "        p.sequence_type ='$sequence_type' ";
    $sql   .= $final_clause;

    if(defined($self->maxdump())){
      $sql .= " LIMIT ".$self->maxdump()." ";
    }

    my $sth = $xref->dbi()->prepare($sql);
    $sth->execute();
    while(my @row = $sth->fetchrow_array()){

      $row[1] =~ s/(.{60})/$1\n/g;
      print XREF_DUMP ">".$row[0]."\n".$row[1]."\n";

    }

    close(XREF_DUMP);
    $sth->finish();

  }

}

=head2 dump_ensembl

  Description: Dumps the ensembl data to a file in fasta format.
  Returntype : none
  Exceptions : none
  Caller     : dump_seqs

=cut

sub dump_ensembl{
  my ($self, $location) = @_;

  $self->fetch_and_dump_seq($location);

}


=head2 fetch_and_dump_seq

  Description: Dumps the ensembl data to a file in fasta format.
  Returntype : none
  Exceptions : wil die if the are errors in db connection or file creation.
  Caller     : dump_ensembl

=cut

sub fetch_and_dump_seq{
  my ($self, $location) = @_;

  my $db = new Bio::EnsEMBL::DBSQL::DBAdaptor(-species => $self->species(),
					      -dbname  => $self->dbname(),
					      -host    => $self->host(),
					      -port    => $self->port(),
					      -pass    => $self->password(),
					      -user    => $self->user(),
					      -group   => 'core');

  #
  # store ensembl dna file name and open it
  #
  
  # if no directory set then dump in the current directory.
  if(!defined($self->dir())){
    $self->dir(".");
  }
  $self->ensembl_dna_file($self->dir."/".$self->species."_dna.fasta");
  #
  # store ensembl protein file name and open it
  #
  $self->ensembl_protein_file($self->dir."/".$self->species."_protein.fasta");

  if(defined($self->dumpcheck()) and -e $self->ensembl_protein_file() and -e $self->ensembl_dna_file()){
    return;
  }
  open(DNA,">".$self->ensembl_dna_file()) 
    || die("Could not open dna file for writing: ".$self->ensembl_dna_file."\n");

  open(PEP,">".$self->ensembl_protein_file()) 
    || die("Could not open protein file for writing: ".$self->ensembl_protein_file."\n");

  my $gene_adaptor = $db->get_GeneAdaptor();


  # fetch by location, or everything if not defined
  my @genes;
  if ($location) {

    my $slice_adaptor = $db->get_SliceAdaptor();
    my $slice = $slice_adaptor->fetch_by_name($location);
    @genes = @{$gene_adaptor->fetch_all_by_Slice($slice)};

  } else {

    @genes = @{$gene_adaptor->fetch_all()};

  }

  my $max = undef;
  if(defined($self->maxdump())){
    $max = $self->maxdump();
  }
  my $i =0;
  foreach my $gene (@genes){
    foreach my $transcript (@{$gene->get_all_Transcripts()}) {
      $i++;
      my $seq = $transcript->spliced_seq(); 
      $seq =~ s/(.{60})/$1\n/g;
      print DNA ">" . $transcript->dbID() . "\n" .$seq."\n";
      my $trans = $transcript->translation();
      my $translation = $transcript->translate();

      if(defined($translation)){
	my $pep_seq = $translation->seq();
	$pep_seq =~ s/(.{60})/$1\n/g;
	print PEP ">".$trans->dbID()."\n".$pep_seq."\n";
      }
    }

    last if(defined($max) and $i > $max);

  }

  close DNA;
  close PEP;

}



###
# Getter/Setter methods
###



#=head2 xref_protein_file
# 
#  Arg [1]    : (optional) string $arg
#               the fasta file name for the protein xref
#  Example    : $file name = $xref->xref_protein_file();
#  Description: Getter / Setter for the protien xref fasta file 
#  Returntype : string
#  Exceptions : none
#
#=cut
#
#
#sub xref_protein_file{
#  my ($self, $arg) = @_;
#
#  (defined $arg) &&
#    ($self->{_xref_prot_file} = $arg );
#  return $self->{_xref_prot_file};
#}
#
#=head2 xref_dna_file
#
#  Arg [1]    : (optional) string $arg
#               the fasta file name for the dna xref
#  Example    : $file name = $xref->xref_dna_file();
#  Description: Getter / Setter for the dna xref fasta file 
#  Returntype : string
#  Exceptions : none
#
#=cut
#
#sub xref_dna_file{
#  my ($self, $arg) = @_;
#
#  (defined $arg) &&
#    ($self->{_xref_dna_file} = $arg );
#  return $self->{_xref_dna_file};
#}

=head2 ensembl_protein_file
 
  Arg [1]    : (optional) string $arg
               the fasta file name for the ensembl proteins 
  Example    : $file_name = $self->ensembl_protein_file();
  Description: Getter / Setter for the protien ensembl fasta file 
  Returntype : string
  Exceptions : none

=cut

sub ensembl_protein_file{
  my ($self, $arg) = @_;

  (defined $arg) &&
    ($self->{_ens_prot_file} = $arg );
  return $self->{_ens_prot_file};
}

=head2 ensembl_dna_file
 
  Arg [1]    : (optional) string $arg
               the fasta file name for the ensembl dna 
  Example    : $file_name = $self->ensembl_dna_file();
  Description: Getter / Setter for the protien ensembl fasta file 
  Returntype : string
  Exceptions : none

=cut

sub ensembl_dna_file{
  my ($self, $arg) = @_;

  (defined $arg) &&
    ($self->{_ens_dna_file} = $arg );
  return $self->{_ens_dna_file};
}

=head2 method
 
  Arg [1]    : (optional) list reference $arg
               reference to a list of method names 
  Example    : my @methods = @{$self->method()};
  Description: Getter / Setter for the methods 
  Returntype : list
  Exceptions : none

=cut


sub method{
  my ($self, $arg) = @_;

  (defined $arg) &&
    ($self->{_method} = $arg );
  return $self->{_method};
}


sub xref{
  my ($self, $arg) = @_;

  (defined $arg) &&
    ($self->{_xref} = $arg );
  return $self->{_xref};
}

=head2 run_mapping

  Arg[1]     : List of lists of (method, query, target)
  Arg[2]     :
  Example    : none
  Description: Create and submit mapping jobs to LSF, and wait for them to finish.
  Returntype : none
  Exceptions : none
  Caller     : general

=cut

sub run_mapping {

  my ($self, $lists) = @_;

  # delete old output files in target directory if we're going to produce new ones
  if (!defined($self->use_existing_mappings)) {
    my $dir = $self->dir();
    unlink (<$dir/*.map $dir/*.out $dir/*.err>);
  }

  # foreach method, submit the appropriate job & keep track of the job name
  # note we check if use_existing_mappings is set here, not earlier, as we
  # still need to instantiate the method object in order to fill
  # method_query_threshold and method_target_threshold

  my @job_names;

  foreach my $list (@$lists){

    my ($method, $queryfile ,$targetfile)  =  @$list;

    my $obj_name = "XrefMapper::Methods::$method";
    # check that the appropriate object exists
    eval "require $obj_name";
    if($@) {

      warn("Could not find object $obj_name corresponding to mapping method $method, skipping\n$@");

    } else {

      my $obj = $obj_name->new();
      $method_query_threshold{$method} = $obj->query_identity_threshold();
      $method_target_threshold{$method} = $obj->target_identity_threshold();

      if (!defined($self->use_existing_mappings)) {
	my $job_name = $obj->run($queryfile, $targetfile, $self->dir());
	push @job_names, $job_name;
	sleep 1; # make sure unique names really are unique
      }
    }

  } # foreach method

  if (!defined($self->use_existing_mappings)) {
    # submit depend job to wait for all mapping jobs
    submit_depend_job($self->dir, @job_names);
  }

} # run_mapping


=head2 submit_depend_job

  Arg[1]     : List of job names.
  Arg[2]     :
  Example    : none
  Description: Submit an LSF job that waits for other jobs to finish.
  Returntype : none
  Exceptions : none
  Caller     : general

=cut

sub submit_depend_job {

  my ($root_dir, @job_names) = @_;

  # Submit a job that does nothing but wait on the main jobs to
  # finish. This job is submitted interactively so the exec does not
  # return until everything is finished.

  # build up the bsub command; first part
  my @depend_bsub = ('bsub', '-K');

  # build -w 'ended(job1) && ended(job2)' clause
  my $ended_str = "-w ";
  my $i = 0;
  foreach my $job (@job_names) {
    $ended_str .= "ended($job)";
    $ended_str .= " && " if ($i < $#job_names);
    $i++;
  }

  push @depend_bsub, $ended_str;

  # rest of command
  push @depend_bsub, ('-q', 'small', '-o', "$root_dir/depend.out", '-e', "$root_dir/depend.err");

  #print "##depend bsub:\n" . join (" ", @depend_bsub) . "\n";

  my $jobid = 0;

  eval {
    my $pid;
    my $reader;

    local *BSUB;
    local *BSUB_READER;

    if (($reader = open(BSUB_READER, '-|'))) {
      while (<BSUB_READER>) {
	if (/^Job <(\d+)> is submitted/) {
	  $jobid = $1;
	  print "LSF job ID for depend job: $jobid\n"
	}
      }
      close(BSUB_READER);
    } else {
      die("Could not fork : $!\n") unless (defined($reader));
      open(STDERR, ">&STDOUT");
      if (($pid = open(BSUB, '|-'))) {
	
	print BSUB "/bin/true\n";
	close BSUB;
	if ($? != 0) {
	  die("bsub exited with non-zero status ($?) - job not submitted\n");
	}
      } else {
	if (defined($pid)) {
	  exec(@depend_bsub);
	  die("Could not exec bsub : $!\n");
	} else {
	  die("Could not fork : $!\n");
	}
      }
      exit(0);
    }
  };

  if ($@) {
    # Something went wrong
    warn("Job submission failed:\n$@\n");
  }

}

=head2 parse_mappings

  Arg[1]     : The target file used in the exonerate run. Used to work out the Ensembl object type.
  Arg[2]     :
  Example    : none
  Description: Parse exonerate output files and build files for loading into target db tables.
  Returntype : List of strings
  Exceptions : none
  Caller     : general

=cut

sub parse_mappings {

  my ($self, $xref) = @_;

  my $dir = $self->dir();

  # get current max object_xref_id
  my $row = @{$core_dbi->selectall_arrayref("SELECT MAX(object_xref_id) FROM object_xref")}[0];
  my $max_object_xref_id = @{$row}[0];
  if (!defined $max_object_xref_id) {
    print "Can't get highest existing object_xref_id, using 1\n";
    $max_object_xref_id = 1;
  } else {
    print "Maximum existing object_xref_id = $max_object_xref_id\n";
  }
  my $object_xref_id_offset = $max_object_xref_id + 1;
  my $object_xref_id = $object_xref_id_offset;

  $row = @{$self->dbi->selectall_arrayref("SELECT MAX(xref_id) FROM xref")}[0];
  my $max_xref_id = @$row[0];
  if (!defined $max_xref_id) {
    print "Can't get highest existing xref_id, using 1\n";
    $max_xref_id = 1;
  } else {
    print "Maximum existing xref_id = $max_xref_id\n";
  }
  my $xref_id_offset = $max_xref_id + 1;

  # files to write table data to
  open (OBJECT_XREF,   ">$dir/object_xref.txt");
  open (IDENTITY_XREF, ">$dir/identity_xref.txt");

  my $total_lines = 0;
  my $last_lines = 0;
  my $total_files = 0;

  # keep a (unique) list of xref IDs that need to be written out to file as well
  # this is a hash of hashes, keyed on xref id that relates xrefs to e! objects (may be 1-many)
  my %primary_xref_ids = ();

  # also keep track of types of ensembl objects
  my %ensembl_object_types;

  # and a list of mappings of ensembl objects to xrefs
  # (primary now, dependent added in dump_core_xrefs)
  # this is required for display_xref generation later
  # format:
  #   key: ensembl object type:ensembl object id
  #   value: list of xref_id (with offset)
  # Note %object_xref_mappings is global


  foreach my $file (glob("$dir/*.map")) {

    #print "Parsing results from " . basename($file) .  "\n";
    open(FILE, $file);
    $total_files++;

    # files are named Method_(dna|peptide)_N.map
    my $type = get_ensembl_object_type($file);

    my $method = get_method($file);

    # get or create the appropriate analysis ID
    # XXX restore when using writeable database
    #my $analysis_id = $self->get_analysis_id($type);
    my $analysis_id = 999;

    while (<FILE>) {

      $total_lines++;
      chomp();
      my ($label, $query_id, $target_id, $identity, $query_length, $target_length, $query_start, $query_end, $target_start, $target_end, $cigar_line, $score) = split(/:/, $_);
      $cigar_line =~ s/ //g;

      # calculate percentage identities
      my $query_identity = int (100 * $identity / $query_length);
      my $target_identity = int (100 * $identity / $target_length);

      # only take mappings where there is a good match on one or both sequences
      next if ($query_identity  < $method_query_threshold{$method} &&
	       $target_identity < $method_target_threshold{$method});

      # note we add on $xref_id_offset to avoid clashes
      print OBJECT_XREF "$object_xref_id\t$target_id\t$type\t" . ($query_id+$xref_id_offset) . "\n";
      print IDENTITY_XREF join("\t", ($object_xref_id, $query_identity, $target_identity, $query_start+1, $query_end, $target_start+1, $target_end, $cigar_line, $score, "\\N", $analysis_id)) . "\n";

      # TODO - evalue?
      $object_xref_id++;

      $ensembl_object_types{$target_id} = $type;

      # store mapping for later - note NON-OFFSET xref_id is used
      my $key = $type . "|" . $target_id;
      my $xref_id = $query_id;
      push @{$object_xref_mappings{$key}}, $xref_id;

      # store query & target identities
      # Note this is a hash (object id) of hashes (xref id) of hashes ("query_identity" or "target_identity")
      $object_xref_identities{$target_id}->{$xref_id}->{"query_identity"} = $query_identity;
      $object_xref_identities{$target_id}->{$xref_id}->{"target_identity"} = $target_identity;

      # note the NON-OFFSET xref_id is stored here as the values are used in
      # a query against the original xref database
      $primary_xref_ids{$query_id}{$target_id} = $target_id;

    }

    close(FILE);
    #print "After $file, lines read increased by " . ($total_lines-$last_lines) . "\n";
    $last_lines = $total_lines;
  }

  close(IDENTITY_XREF);
  close(OBJECT_XREF);

  print "Read $total_lines lines from $total_files exonerate output files\n";

  # write relevant xrefs to file
  my $max_object_xref_id = $self->dump_core_xrefs(\%primary_xref_ids, $object_xref_id+1, $xref_id_offset, $object_xref_id_offset, \%ensembl_object_types);

  # dump xrefs that don't appear in either the primary_xref or dependent_xref tables
  $self->dump_orphan_xrefs($xref_id_offset);

  # dump interpro table as well
  $self->dump_interpro();

  # dump direct xrefs
  $self->dump_direct_xrefs($xref_id_offset, $max_object_xref_id);

  # write comparison info. Can be removed after development
  ###writes to xref.txt.Do not want to do this if loading data afterwards
  ####  $self->dump_comparison();

}

# dump xrefs that don't appear in either the primary_xref or dependent_xref tables
# e.g. Interpro xrefs

sub dump_orphan_xrefs() {

  my ($self, $xref_id_offset) = @_;

  my $count;

  open (XREF, ">>" . $self->dir() . "/xref.txt");

  # need a double left-join
  my $sql = "SELECT x.xref_id, x.accession, x.version, x.label, x.description, x.source_id, x.species_id FROM xref x LEFT JOIN primary_xref px ON px.xref_id=x.xref_id LEFT JOIN dependent_xref dx ON dx.dependent_xref_id=x.xref_id WHERE px.xref_id IS NULL AND dx.dependent_xref_id IS NULL";

  my $sth = $xref_dbi->prepare($sql);
  $sth->execute();

  my ($xref_id, $accession, $version, $label, $description, $source_id, $species_id);
  $sth->bind_columns(\$xref_id, \$accession, \$version, \$label, \$description, \$source_id, \$species_id);

  while ($sth->fetch()) {

    my $external_db_id = $source_to_external_db{$source_id};
    if ($external_db_id) { # skip "unknown" sources
      if (!$xrefs_written{$xref_id}) {
	print XREF ($xref_id+$xref_id_offset) . "\t" . $external_db_id . "\t" . $accession . "\t" . $label . "\t" . $version . "\t" . $description . "\n";
	$xrefs_written{$xref_id} = 1;
	$count++;
      }
    }

  }
  $sth->finish();

  close(XREF);

  print "Wrote $count xrefs that are neither primary nor dependent\n";

}

# Dump direct xrefs. Need to do stable ID -> internal ID mapping.

sub dump_direct_xrefs {

  my ($self, $xref_id_offset, $max_object_xref_id) = @_;
  my $object_xref_id = $max_object_xref_id + 1;

  print "Writing direct xrefs\n";

  my $count = 0;

  open (XREF, ">>" . $self->dir() . "/xref.txt");
  open (OBJECT_XREF, ">>" . $self->dir() . "/object_xref.txt");

  # Will need to look up translation stable ID from transcript stable ID, build hash table
  print "Building transcript stable ID -> translation stable ID lookup table\n";
  my %transcript_stable_id_to_translation_stable_id;
  my $trans_sth = $core_dbi->prepare("SELECT tss.stable_id as transcript, tls.stable_id AS translation FROM translation tl, translation_stable_id tls, transcript_stable_id tss WHERE tss.transcript_id=tl.transcript_id AND tl.translation_id=tls.translation_id");
  $trans_sth->execute();
  my ($transcript_stable_id, $translation_stable_id);
  $trans_sth->bind_columns(\$transcript_stable_id, \$translation_stable_id);
  while ($trans_sth->fetch()) {
    $transcript_stable_id_to_translation_stable_id{$transcript_stable_id} = $translation_stable_id;
  }
  $trans_sth->finish();

  # Will need lookup tables for gene/transcript/translation stable ID to internal ID
  my $stable_id_to_internal_id = $self->build_stable_id_to_internal_id_hash();

  # SQL / statement handle for getting all direct xrefs
  my $xref_sql = "SELECT dx.general_xref_id, dx.ensembl_stable_id, dx.type, dx.linkage_xref, x.accession, x.version, x.label, x.description, x.source_id, x.species_id FROM direct_xref dx, xref x WHERE dx.general_xref_id=x.xref_id";
  my $xref_sth = $xref_dbi->prepare($xref_sql);

  $xref_sth->execute();

  my ($xref_id, $ensembl_stable_id, $type, $linkage_xref, $accession, $version, $label, $description, $source_id, $species_id);
  $xref_sth->bind_columns(\$xref_id, \$ensembl_stable_id, \$type, \$linkage_xref,\ $accession, \$version, \$label, \$description, \$source_id, \$species_id);

  while ($xref_sth->fetch()) {

    my $external_db_id = $source_to_external_db{$source_id};
    if ($external_db_id) {

      # In the case of CCDS xrefs, direct_xref is to transcript but we want
      # the mapping in the core db to be to the *translation*
      if ($source_id == get_source_id_from_source_name($self->xref(), "CCDS")) {
	$type = 'translation';
	my $tmp_esid = $ensembl_stable_id;
	$ensembl_stable_id = $transcript_stable_id_to_translation_stable_id{$tmp_esid};
	warn "Can't find translation for transcript $tmp_esid" if (!$ensembl_stable_id);
	#print "CCDS: transcript $tmp_esid -> translation $ensembl_stable_id\n";
      }

      my $ensembl_internal_id = $stable_id_to_internal_id->{$type}->{$ensembl_stable_id};

      # horrible hack to deal with UTR transcripts in Elegans
      my $postfix = 1;
      while (!$ensembl_internal_id && $postfix < 5) {
	my $utr_stable_id = $ensembl_stable_id . ".$postfix" ;
	$ensembl_internal_id = $stable_id_to_internal_id->{$type}->{$utr_stable_id};
	$postfix++;
      }
      # end horrible hack

      if ($ensembl_internal_id) {

	if (!$xrefs_written{$xref_id}) {
	  print XREF ($xref_id+$xref_id_offset) . "\t" . $external_db_id . "\t" . $accession . "\t" . $label . "\t" . $version . "\t" . $description . "\n";
	  $xrefs_written{$xref_id} = 1;
	}
	print OBJECT_XREF "$object_xref_id\t$ensembl_internal_id\t" . ucfirst($type) . "\t" . ($xref_id+$xref_id_offset) . "\n";
	$object_xref_id++;
	$count++;

      } else {

	print STDERR "Can't find $type corresponding to stable ID $ensembl_stable_id in ${type}_stable_id, not writing record for xref $accession\n";

      }

    }

  }

  close(OBJECT_XREF);
  close(XREF);

  $xref_sth->finish();

  print "Wrote $count direct xrefs\n";

}


# Dump the interpro table from the xref database
sub dump_interpro {

  my $self = shift;

  open (INTERPRO, ">" .  $self->dir() . "/interpro.txt");

  my $sth = $xref_dbi->prepare("SELECT * FROM interpro");
  $sth->execute();

  my ($interpro, $pfam);
  $sth->bind_columns(\$interpro, \$pfam);
  while ($sth->fetch()) {
    print INTERPRO $interpro . "\t" . $pfam . "\n";
  }
  $sth->finish();

  close (INTERPRO);

}

sub build_stable_id_to_internal_id_hash {

  my ($self) = @_;

  my %stable_id_to_internal_id;

  foreach my $type ('gene', 'transcript', 'translation') { # Add exon here if required

    print "Caching stable ID -> internal ID links for ${type}s\n";

    my $core_sql = "SELECT ${type}_id, stable_id FROM ${type}_stable_id" ;
    my $sth = $core_dbi->prepare($core_sql);
    $sth->execute();
    my ($internal_id, $stable_id);
    $sth->bind_columns(\$internal_id, \$stable_id);

    while ($sth->fetch) {

      $stable_id_to_internal_id{$type}{$stable_id} = $internal_id;

    }

  }

  return \%stable_id_to_internal_id;

}

sub get_ensembl_object_type {

  my $filename = shift;
  my $type;

  $filename = basename($filename);

  if ($filename =~ /_dna_/i) {

    $type = "Transcript";

  } elsif ($filename =~ /_peptide_/i) {

    $type = "Translation";

  } else {

    print STDERR "Cannot deduce Ensembl object type from filename $filename\n";
  }

  return $type;

}

sub get_method {

  my $filename = shift;

  $filename = basename($filename);

  my ($method) = $filename =~ /^(.*)_(dna|peptide)_\d+\.map/;

  return $method;

}

sub get_analysis_id {

  my ($self, $ensembl_type) = @_;

  my %typeToLogicName = ( 'dna' => 'XrefExonerateDNA',
			  'protein' => 'XrefExonerateProtein' );

  my $logic_name = $typeToLogicName{lc($ensembl_type)};

  my $sth = $core_dbi->prepare("SELECT analysis_id FROM analysis WHERE logic_name='" . $logic_name ."'");
  $sth->execute();

  my $analysis_id;

  if (my @row = $sth->fetchrow_array()) {

    $analysis_id = $row[0];
    print "Found exising analysis ID ($analysis_id) for $logic_name\n";

  } else {

    print "No analysis with logic_name $logic_name found, creating ...\n";
    $sth = $core_dbi->prepare("INSERT INTO analysis (logic_name, created) VALUES ('" . $logic_name. "', NOW())");
    # TODO - other fields in analysis table
    $sth->execute();
    $analysis_id = $sth->{'mysql_insertid'};
    print "Done (analysis ID=" . $analysis_id. ")\n";

  }

  return $analysis_id;

}


sub dump_core_xrefs {

  my ($self, $xref_ids_hashref, $start_object_xref_id, $xref_id_offset, $object_xref_id_offset,  $ensembl_object_types_hashref) = @_;

  my @xref_ids = keys %$xref_ids_hashref;
  my %xref_to_objects = %$xref_ids_hashref;
  my %ensembl_object_types = %$ensembl_object_types_hashref;

  my $dir = $self->dir();

  open (XREF, ">$dir/xref.txt");
  open (OBJECT_XREF, ">>$dir/object_xref.txt");
  open (EXTERNAL_SYNONYM, ">$dir/external_synonym.txt");
  open (GO_XREF, ">$dir/go_xref.txt");

  # keep a unique list of source IDs to build the external_db table later
  my %source_ids;

  my $object_xref_id = $start_object_xref_id;

  # build cache of source id -> external_db id; note %source_to_external_db is global
  %source_to_external_db = $self->map_source_to_external_db();

  # execute several queries with a max of 200 entries in each IN clause - more efficient
  my $batch_size = 200;

  # keep track of what xref_id & object_xref_ids have been written to prevent
  # duplicates; e.g. several dependent xrefs may be dependent on the same master xref.
  # Note %xrefs_written and %object_xrefs_written are global

  while(@xref_ids) {

    my @ids;
    if($#xref_ids > $batch_size) {
      @ids = splice(@xref_ids, 0, $batch_size);
    } else {
      @ids = splice(@xref_ids, 0);
    }

    my $id_str;
    if(@ids > 1)  {
      $id_str = "IN (" . join(',', @ids). ")";
    } else {
      $id_str = "= " . $ids[0];
    }


    my $sql = "SELECT * FROM xref WHERE xref_id $id_str";
    my $xref_sth = $xref_dbi->prepare($sql);
    $xref_sth->execute();

    my ($xref_id, $accession, $version, $label, $description, $source_id, $species_id, $master_xref_id, $linkage_annotation);
    $xref_sth->bind_columns(\$xref_id, \$accession, \$version, \$label, \$description, \$source_id, \$species_id);

    # note the xref_id we write to the file is NOT the one we've just read
    # from the internal xref database as the ID may already exist in the
    # core database so we add on $xref_id_offset
    while ($xref_sth->fetch()) {

      # make sure label is set to /something/ so that the website displays something
      $label = $accession if (!$label);

      if (!$xrefs_written{$xref_id}) {
	my $external_db_id = $source_to_external_db{$source_id};
	if ($external_db_id) { # skip "unknown" sources
	  print XREF ($xref_id+$xref_id_offset) . "\t" . $external_db_id . "\t" . $accession . "\t" . $label . "\t" . $version . "\t" . $description . "\n";
	  $xrefs_written{$xref_id} = 1;
	  $source_ids{$source_id} = $source_id;
	}
      }
    }

    # Now get the dependent xrefs for each of these xrefs and write them as well
    # Store the go_linkage_annotations as we go along (need for dumping go_xref)
    my $go_source_id = get_source_id_from_source_name($self->xref, "GO");

    $sql = "SELECT DISTINCT(x.xref_id), dx.master_xref_id, x.accession, x.label, x.description, x.source_id, x.version, dx.linkage_annotation FROM dependent_xref dx, xref x WHERE x.xref_id=dx.dependent_xref_id AND master_xref_id $id_str";

    my $dep_sth = $xref_dbi->prepare($sql);
    $dep_sth->execute();

    $dep_sth->bind_columns(\$xref_id, \$master_xref_id, \$accession, \$label, \$description, \$source_id, \$version, \$linkage_annotation);
    while ($dep_sth->fetch()) {

      my $external_db_id = $source_to_external_db{$source_id};
      next if (!$external_db_id);

      $label = $accession if (!$label);

      if (!$xrefs_written{$xref_id}) {
	print XREF ($xref_id+$xref_id_offset) . "\t" . $external_db_id . "\t" . $accession . "\t" . $label . "\t" . $version . "\t" . $description . "\tDEPENDENT\n";
	$xrefs_written{$xref_id} = 1;
	$source_ids{$source_id} = $source_id;
      }

      # create an object_xref linking this (dependent) xref with any objects it maps to
      # write to file and add to object_xref_mappings
      if (defined $xref_to_objects{$master_xref_id}) {
	my @ensembl_object_ids = keys( %{$xref_to_objects{$master_xref_id}} ); 
	#print "xref $accession has " . scalar(@ensembl_object_ids) . " associated ensembl objects\n";
	foreach my $object_id (@ensembl_object_ids) {
	  my $type = $ensembl_object_types{$object_id};
	  my $full_key = $type."|".$object_id."|".$xref_id;
	  if (!$object_xrefs_written{$full_key}) {
	    print OBJECT_XREF "$object_xref_id\t$object_id\t$type\t" . ($xref_id+$xref_id_offset) . "\tDEPENDENT\n";

	    # Add this mapping to the list - note NON-OFFSET xref_id is used
	    my $key = $type . "|" . $object_id;
	    push @{$object_xref_mappings{$key}}, $xref_id;
	    $object_xrefs_written{$full_key} = 1;

	    # Also store *parent's* query/target identity for dependent xrefs
	    $object_xref_identities{$object_id}->{$xref_id}->{"target_identity"} = $object_xref_identities{$object_id}->{$master_xref_id}->{"target_identity"};
	    $object_xref_identities{$object_id}->{$xref_id}->{"query_identity"} = $object_xref_identities{$object_id}->{$master_xref_id}->{"query_identity"};

	    # write a go_xref with the appropriate linkage type
	    print GO_XREF $object_xref_id . "\t" . $linkage_annotation . "\n"  if ($source_id == $go_source_id);

	    $object_xref_id++;

	  }
	}
      }
    }

    # Now get the synonyms for each of these xrefs and write them to the external_synonym table
    $sql = "SELECT DISTINCT xref_id, synonym FROM synonym WHERE xref_id $id_str";

    my $syn_sth = $xref_dbi->prepare($sql);
    $syn_sth->execute();

    $syn_sth->bind_columns(\$xref_id, \$accession);
    while ($syn_sth->fetch()) {

      print EXTERNAL_SYNONYM ($xref_id+$xref_id_offset) . "\t" . $accession . "\n";

    }

    #print "source_ids: " . join(" ", keys(%source_ids)) . "\n";

  } # while @xref_ids

  close(XREF);
  close(OBJECT_XREF);
  close(EXTERNAL_SYNONYM);
  close(GO_XREF);

  print "Before calling display_xref, object_xref_mappings size " . scalar (keys %object_xref_mappings) . "\n";

  # calculate display_xref_ids for transcripts and genes
  my $transcript_display_xrefs = $self->build_transcript_display_xrefs($xref_id_offset);

  build_genes_to_transcripts();

  $self->build_gene_display_xrefs($transcript_display_xrefs);

  # now build gene descriptions
  $self->build_gene_descriptions();

  return $object_xref_id;

}


# produce output for comparison with existing ensembl mappings
# format is (with header)
# xref_accession ensembl_type ensembl_id

sub dump_comparison {

  my $self = shift;

  my $dir = $self->dir();

  print "Dumping comparison data\n";

  open (COMPARISON, ">comparison/xref_mappings.txt");
  print COMPARISON "xref_accession" . "\t" . "ensembl_type" . "\t" . "ensembl_id\n";

  # get the xref accession for each xref as the xref_ids are ephemeral
  # first read all the xrefs that were dumped and get an xref_id->accession map
  my %xref_id_to_accesson;
  open (XREF, "$dir/xref.txt");
  while (<XREF>) {
    my ($xref_id,$external_db_id,$accession,$label,$version,$description) = split;
    $xref_id_to_accesson{$xref_id} = $accession;
  }
  close (XREF);

  open (OBJECT_XREF, "$dir/object_xref.txt");
  while (<OBJECT_XREF>) {
    my ($object_xref_id,$object_id,$type,$xref_id) = split;
    print COMPARISON $xref_id_to_accesson{$xref_id} . "\t" . $type . "\t" . $object_id . "\n";
  }

  close (OBJECT_XREF);
  close (COMPARISON);

}

sub build_transcript_display_xrefs {

  my ($self, $xref_id_offset) = @_;

  my $dir = $self->dir();

  # get a list of xref sources; format:
  # key: xref_id value: source_name
  # lots of these; if memory is a problem, just get the source ID (not the name)
  # and look it up elsewhere
  # note %xref_to_source is global
  print "Building xref->source mapping table\n";
  my $sql = "SELECT x.xref_id, s.name FROM source s, xref x WHERE x.source_id=s.source_id";
  my $sth = $xref_dbi->prepare($sql);
  $sth->execute();

  my ($xref_id, $source_name);
  $sth->bind_columns(\$xref_id, \$source_name);

  while ($sth->fetch()) {
    $xref_to_source{$xref_id} = $source_name;
  }

  print "Got " . scalar(keys %xref_to_source) . " xref-source mappings\n";

  # Cache the list of translation->transcript mappings & vice versa
  # Nte variables are global
  print "Building translation to transcript mappings\n";
  my $sth = $core_dbi->prepare("SELECT translation_id, transcript_id FROM translation");
  $sth->execute();

  my ($translation_id, $transcript_id);
  $sth->bind_columns(\$translation_id, \$transcript_id);

  while ($sth->fetch()) {
    $translation_to_transcript{$translation_id} = $transcript_id;
    $transcript_to_translation{$transcript_id} = $translation_id if ($translation_id);
  }

  print "Building transcript display_xrefs\n";
  my @priorities = $self->transcript_display_xref_sources();

  my $n = 0;

  # go through each object/xref mapping and store the best ones as we go along
  my %obj_to_best_xref;

  foreach my $key (keys %object_xref_mappings) {

    my ($type, $object_id) = split /\|/, $key;

    next if ($type !~ /(Transcript|Translation)/i);

    # if a transcript has more than one associated xref,
    # use the one with the highest priority, i.e. lower list position in @priorities
    my @xrefs = @{$object_xref_mappings{$key}};
    my ($best_xref, $best_xref_priority_idx);
    # store best query & target identities for each source
    my %best_qi;
    my %best_ti;
    $best_xref_priority_idx = 99999;
    foreach my $xref (@xrefs) {

      my $source = $xref_to_source{$xref};
      if ($source) {
	my $i = find_in_list($source, @priorities);

	my $s = $source . "|" . $xref;
	my $query_identity = $object_xref_identities{$object_id}->{$xref}->{"query_identity"};
	my $target_identity = $object_xref_identities{$object_id}->{$xref}->{"target_identity"};

      print "###$type $object_id: xref $xref pri $i qi $query_identity\n" if ((($object_id == 93561 && $type =~ /Transcript/) || ($object_id == 65810 && $type =~ /Translation/)) && $i == 0);
	print "xref $xref $type $object_id pri $i qi $query_identity best qi " . $best_qi{$s} . " ti $target_identity\n" if ($xref == 397813 || $xref == 397814);
	# Check if this source has a better priority than the current best one
	# Note if 2 sources are the same priority, the mappings are compared on
	# query_identity then target_identity
#	if ($i > -1 && $i < $best_xref_priority_idx &&
#	    (($query_identity > $best_query_identity) ||
#	    ($query_identity == $best_query_identity && $target_identity > $best_target_identity))) {
	if ($i > -1 && $i < $best_xref_priority_idx && $query_identity > $best_qi{$s}) {
	  $best_xref = $xref;
	  $best_xref_priority_idx = $i;
	  $best_qi{$s} = $query_identity;
	  print "Setting best qi $s to $query_identity\n" if ($xref == 397813 || $xref == 397814);
	  $best_ti{$s} = $target_identity;
	}
      } else {
	warn("Couldn't find a source for xref $xref \n");
      }
    }
    # store object type, id, and best xref id and source priority
    if ($best_xref) {
      print "##setting obj to best xref $key to $best_xref | $best_xref_priority_idx\n" if ($best_xref == 397813 || $best_xref == 397814);
      $obj_to_best_xref{$key} = $best_xref . "|" . $best_xref_priority_idx;
    }

  }

  # Now go through each of the calculated best xrefs and convert any that are
  # calculated against translations to be associated with their transcript,
  # if the priority of the translation xref is higher than that of the transcript
  # xref.
  # Needs to be done this way to avoid clobbering higher-priority transcripts.

  # hash keyed on transcript id, value is xref_id|source prioirity index
  my %transcript_display_xrefs;

  # Write a .sql file that can be executed, and a .txt file that can be processed
  open (TRANSCRIPT_DX, ">$dir/transcript_display_xref.sql");
  open (TRANSCRIPT_DX_TXT, ">$dir/transcript_display_xref.txt");

  foreach my $key (keys %obj_to_best_xref) {

    my ($type, $object_id) = split /\|/, $key;

    my ($best_xref, $best_xref_priority_idx) = split /\|/, $obj_to_best_xref{$key};

    # If transcript has a translation, use the best xref out of the transcript & translation

    my $transcript_id;
    my $translation_id;
    if ($type =~ /Transcript/i) {
      $transcript_id = $object_id;
      $translation_id = $transcript_to_translation{$transcript_id};
    }
    elsif ($type =~ /Translation/i) {
      $translation_id = $object_id;
      $transcript_id = $translation_to_transcript{$translation_id};
      $object_id = $transcript_id;
    }
    else{
      print "Cannot deal with type $type\n";
      next;
    }
    if ($translation_id) {
      my ($translation_xref, $translation_priority) = split /\|/, $obj_to_best_xref{"Translation|$translation_id"};
      my ($transcript_xref, $transcript_priority)   = split /\|/, $obj_to_best_xref{"Transcript|$transcript_id"};
      my $transcript_qi = $object_xref_identities{$object_id}->{$transcript_xref}->{"query_identity"};
      my $translation_qi = $object_xref_identities{$object_id}->{$translation_xref}->{"query_identity"};

print "translation 65810: translation xref: $translation_xref $translation_priority transcript_xref $transcript_xref $transcript_priority\n" if ($type =~ /Translation/ && $object_id == 65810);
      if(!$translation_xref){
	$best_xref = $transcript_xref;
	$best_xref_priority_idx = $transcript_priority;
      }
      if(!$transcript_xref){
	$best_xref = $translation_xref;
	$best_xref_priority_idx = $translation_priority;
      }
      elsif ($translation_priority < $transcript_priority && $translation_qi > $transcript_qi) {
	$best_xref = $translation_xref;
	$best_xref_priority_idx = $translation_priority;
      } else {
	$best_xref = $transcript_xref;
	$best_xref_priority_idx = $transcript_priority;
      }
      
    }
    if ($best_xref) {

      # Write record with xref_id_offset
      print TRANSCRIPT_DX "UPDATE transcript SET display_xref_id=" . ($best_xref+$xref_id_offset) . " WHERE transcript_id=" . $object_id . ";\n";
      print "wrote " . $best_xref . " (plus offset) for 93591\n" if ($object_id eq 93591);
      print TRANSCRIPT_DX_TXT ($best_xref+$xref_id_offset) . "\t" . $object_id . "\n";
      $n++;

      my $value = ($best_xref+$xref_id_offset) . "|" . $best_xref_priority_idx;
      $transcript_display_xrefs{$object_id} = $value;

    }

  }

  close(TRANSCRIPT_DX);
  close(TRANSCRIPT_DX_TXT);

  print "Wrote $n transcript display_xref entries to transcript_display_xref.sql\n";

  return \%transcript_display_xrefs;

}


# Assign display_xrefs to genes based on transcripts
# Gene gets the display xref of the highest priority of all of its transcripts
# If more than one transcript with the same priority, longer transcript is used

sub build_gene_display_xrefs {

  my ($self, $transcript_display_xrefs) = @_;

  my $dir = $self->dir();

  my $db = new Bio::EnsEMBL::DBSQL::DBAdaptor(-species => $self->species(),
					      -dbname  => $self->dbname(),
					      -host    => $self->host(),
					      -port    => $self->port(),
					      -pass    => $self->password(),
					      -user    => $self->user(),
					      -group   => 'core');
  my $ta = $db->get_TranscriptAdaptor();

  print "Assigning display_xrefs to genes\n";

  open (GENE_DX, ">$dir/gene_display_xref.sql");
  open (GENE_DX_TXT, ">$dir/gene_display_xref.txt");
  my $hit = 0;
  my $miss = 0;
  my $trans_no_xref = 0;
  my $trans_xref = 0;
  foreach my $gene_id (keys %genes_to_transcripts) {

    my @transcripts = @{$genes_to_transcripts{$gene_id}};

    my $best_xref;
    my $best_xref_priority_idx = 99999;
    my $best_transcript_length = -1;
    foreach my $transcript_id (@transcripts) {
      if (!$transcript_display_xrefs->{$transcript_id}) {
	$trans_no_xref++;
	next;
      } else {
	$trans_xref++;
      }
      my ($xref_id, $priority) = split (/\|/, $transcript_display_xrefs->{$transcript_id});
      #print "gene $gene_id orig:" . $transcript_display_xrefs->{$transcript_id} . " xref id: " . $xref_id . " pri " . $priority . "\n";
      # 2 separate if clauses to avoid having to fetch transcripts unnecessarily

      if (($priority lt $best_xref_priority_idx)) {

	$best_xref_priority_idx = $priority;
	$best_xref = $xref_id;

      } elsif ($priority eq $best_xref_priority_idx) {

	# compare transcript lengths and use longest
	my $transcript = $ta->fetch_by_dbID($transcript_id);
	my $transcript_length = $transcript->length();
	if ($transcript_length > $best_transcript_length) {
	  $best_transcript_length = $transcript_length;
	  $best_xref_priority_idx = $priority;
	  $best_xref = $xref_id;
	}
      }
    }

    if ($best_xref) {
      # Write record
      print GENE_DX "UPDATE gene SET display_xref_id=" . $best_xref . " WHERE gene_id=" . $gene_id . ";\n";
      print GENE_DX_TXT $best_xref . "\t" . $gene_id ."\n";
      $hit++;
    } else {
      $miss++;
    }

  }

  close (GENE_DX);
  close (GENE_DX_TXT);
  print "Transcripts with no xrefs: $trans_no_xref with xrefs: $trans_xref\n";
  print "Wrote $hit gene display_xref entries to gene_display_xref.sql\n";
  print "Couldn't find display_xrefs for $miss genes\n" if ($miss > 0);
  print "Found display_xrefs for all genes\n" if ($miss eq 0);

  return \%genes_to_transcripts;

}

# Display xref sources to be used for transcripts *in order of priority*
# Source names used must be identical to those in the source table.

sub transcript_display_xref_sources {

  return ('HUGO',
	  'MarkerSymbol',
#	  'wormbase_transcript',
	  'flybase_symbol',
	  'Anopheles_symbol',
	  'Genoscope_annotated_gene',
	  'Genoscope_predicted_transcript',
	  'Genoscope_predicted_gene',
	  'Uniprot/SWISSPROT',
	  'RefSeq_peptide',
	  'RefSeq_dna',
	  'Uniprot/SPTREMBL',
	  'LocusLink');

}

# Get transcripts associated with each gene

sub build_genes_to_transcripts {

  my ($self) = @_;

  print "Getting transcripts for all genes\n";

  my $sql = "SELECT gene_id, transcript_id FROM transcript";
  my $sth = $core_dbi->prepare($sql);
  $sth->execute();

  my ($gene_id, $transcript_id);
  $sth->bind_columns(\$gene_id, \$transcript_id);

  # Note %genes_to_transcripts is global
  while ($sth->fetch()) {
    push @{$genes_to_transcripts{$gene_id}}, $transcript_id;
  }

  print "Got " . scalar keys(%genes_to_transcripts) . " genes\n";

}

# Find the index of an item in a list(ref), or -1 if it's not in the list.
# Only look for exact matches (case insensitive)

sub find_in_list {

  my ($item, @list) = @_;

  for (my $i = 0; $i < scalar(@list); $i++) {
    if (lc($list[$i]) eq lc($item)) {
      return $i;
    }
  }

  return -1;

}

# Take a string and a list of regular expressions
# Find the index of the highest matching regular expression
# Return the index, or -1 if not found.

sub find_match {

 my ($str, @list) = @_;

 my $str2 = $str;
 my $highest_index = -1;

  for (my $i = 0; $i < scalar(@list); $i++) {
    my $re = $list[$i];
    if ($str2 =~ /$re/i) {
      $highest_index = $i;
    }
  }

  return $highest_index;

}

# Build a map of source id (in xref database) to external_db (in core database)

sub map_source_to_external_db {

  my $self = shift;

  my %source_to_external_db;

  # get all sources
  my $sth = $self->xref->dbi()->prepare("SELECT source_id, name FROM source");
  $sth->execute();
  my ($source_id, $source_name);
  $sth->bind_columns(\$source_id, \$source_name);

  while($sth->fetchrow_array()) {

    # find appropriate external_db_id for each one
    my $sql = "SELECT external_db_id FROM external_db WHERE db_name=?";
    my $core_sth = $core_dbi->prepare($sql);
    $core_sth->execute($source_name);

    my @row = $core_sth->fetchrow_array();

    if (@row) {

      $source_to_external_db{$source_id} = $row[0];
      #print "Source name $source_name id $source_id corresponds to core external_db_id " . $row[0] . "\n";

    } else {

      print STDERR "Can't find external_db entry for source name $source_name; xrefs for this source will not be written. Consider adding $source_name to external_db\n"

    }

  } # while source

  return %source_to_external_db;
}

# Upload .txt files and execute .sql files.

sub do_upload {

  my ($self, $deleteexisting) = @_;

  # xref.txt etc

  # TODO warn if table not empty

  foreach my $table ("xref", "object_xref", "identity_xref", "external_synonym", "gene_description", "go_xref", "interpro") {

    my $file = $self->dir() . "/" . $table . ".txt";
    my $sth;

    if ($deleteexisting) {

      $sth = $core_dbi->prepare("DELETE FROM $table");
      print "Deleting existing data in $table\n";
      $sth->execute();

    }

    # don't seem to be able to use prepared statements here
    $sth = $core_dbi->prepare("LOAD DATA INFILE \'$file\' IGNORE INTO TABLE $table");
    print "Uploading data in $file to $table\n";
    $sth->execute();

  }

  # gene_display_xref.sql etc
  foreach my $table ("gene", "transcript") {

    my $file = $self->dir() . "/" . $table . "_display_xref.sql";
    my $sth;

    if ($deleteexisting) {

      $sth = $core_dbi->prepare("UPDATE $table SET display_xref_id=NULL");
      print "Setting all existing display_xref_id in $table to null\n";
      $sth->execute();

    }

    print "Setting $table display_xrefs from $file\n";
    my $str = "mysql -u " .$self->user() ." -p" . $self->password() . " -h " . $self->host() ." -P " . $self->port() . " " .$self->dbname() . " < $file";
    system $str;

    #$sth = $core_dbi->prepare("UPDATE $table SET display_xref_id=? WHERE ${table}_id=?");
    #open(DX_TXT, $file);
    #while (<DX_TXT>) {
    #  my ($xref_id, $object_id) = split;
    #  $sth->execute($xref_id, $object_id);
    #}
    #close(DX_TXT);
  }

}

# Assign gene descriptions
# Algorithm:
# foreach gene
#   get all transcripts & translations
#   get all associated xrefs
#   filter by regexp, discard blank ones
#   order by source & keyword
#   assign description of best xref to gene
# }
#
# One gene may have several associated peptides; the one to use is decided as follows.
# In decreasing order of precedence:
#
# - Consortium xref, e.g. ZFIN for zebrafish
#
# - UniProt/SWISSPROT
#     If there are several, the one with the best %query_id then %target_id is used
#
# - RefSeq
#    If there are several, the one with the best %query_id then %target_id is used
#
# - UniProt/SPTREMBL
#    If there are several, precedence is established on the basis of the occurrence of 
#    regular expression patterns in the description.

sub build_gene_descriptions {

  my ($self) = @_;

  # TODO - don't call this from, but after, gene_display_xref

  # Get all xref descriptions, filtered by regexp.
  # Discard any that are blank (i.e. regexp has removed everything)

  print "Getting & filtering xref descriptions\n";
 # Note %xref_descriptions & %xref_accessions are global

  my $sth = $self->xref->dbi()->prepare("SELECT xref_id, accession, description FROM xref");
  $sth->execute();
  my ($xref_id, $accession, $description);
  $sth->bind_columns(\$xref_id, \$accession, \$description);

  my $removed = 0;
  my @regexps = $self->gene_description_filter_regexps();
  while ($sth->fetch()) {
    if ($description) {
      $description = filter_by_regexp($description, \@regexps);
      if ($description ne "") {
	$xref_descriptions{$xref_id} = $description;
	$xref_accessions{$xref_id} = $accession;
      } else {
	$removed++;
      }
    }
  }

  print "Regexp filtering (" . scalar(@regexps) . " regexps) removed $removed descriptions, left with " . scalar(keys %xref_descriptions) . "\n";

  my $dir = $self->dir();
  open(GENE_DESCRIPTIONS,">$dir/gene_description.txt") || die "Could not open $dir/gene_description.txt";

  # Foreach gene, get any xrefs associated with its transcripts or translations

  print "Assigning gene descriptions\n";


  foreach my $gene_id (keys %genes_to_transcripts) {

    my @gene_xrefs;

    my %local_xref_to_object;

    my @transcripts = @{$genes_to_transcripts{$gene_id}};
    foreach my $transcript (@transcripts) {

      my @xref_ids;

      my $key = "Transcript|$transcript";
      if ($object_xref_mappings{$key}) {

	@xref_ids = @{$object_xref_mappings{$key}};
	push @gene_xrefs, @xref_ids;
	foreach my $xref (@xref_ids) {
	  $local_xref_to_object{$xref} = $key;
	}
	
      }

      my $translation = $transcript_to_translation{$transcript};
      $key = "Translation|$translation";
      if ($object_xref_mappings{$key}) {

	push @gene_xrefs, @{$object_xref_mappings{$key}} ;
	foreach my $xref (@xref_ids) {
	  $local_xref_to_object{$xref} = $key;
	}
      }
      
    }

    # Now sort through these and find the "best" description and write it

    if (@gene_xrefs) {

      @gene_xrefs = sort {compare_xref_descriptions($self->consortium(), $gene_id, \%local_xref_to_object)} @gene_xrefs;

      my $best_xref = $gene_xrefs[-1];
      my $description = $xref_descriptions{$best_xref};
      my $source = $xref_to_source{$best_xref};
      my $acc = $xref_accessions{$best_xref};

      print GENE_DESCRIPTIONS "$gene_id\t$description" . " [Source:$source;Acc:$acc]\n" if ($description);

    }

  } # foreach gene

  close(GENE_DESCRIPTIONS);

}

# remove a list of patterns from a string
sub filter_by_regexp {

  my ($str, $regexps) = @_;

  foreach my $regexp (@$regexps) {
    $str =~ s/$regexp//ig;
  }

  return $str;

}

# Regexp used for filter out useless text from gene descriptions
# Method can be overridden in species-specific modules
sub gene_description_filter_regexps {

  return ();

}


# The "consortium" source for this species, should be the same as in
# source table

sub consortium {

  return "xxx"; # Default to something that won't be matched as a source

}

# Sort a list of xrefs by the priority of their sources
# Assumed this function is called by Perl sort, passed with parameter
# See comment for build_gene_descriptions for how precedence is decided.

sub compare_xref_descriptions {

  my ($consortium, $gene_id, $xref_to_object) = @_;

  my @sources = ("Uniprot/SPTREMBL", "RefSeq_dna", "RefSeq_peptide", "Uniprot/SWISSPROT", $consortium);
  my @words = qw(unknown hypothetical putative novel probable [0-9]{3} kDa fragment cdna protein);

  my $src_a = $xref_to_source{$a};
  my $src_b = $xref_to_source{$b};
  my $pos_a = find_in_list($src_a, @sources);
  my $pos_b = find_in_list($src_b, @sources);

  # If same source, need to do more work
  if ($pos_a == $pos_b) {

   if ($src_a eq "Uniprot/SWISSPROT" || $src_a =~ /RefSeq/) {

     # Compare on query identities, then target identities if queries are the same
     my $key_a = $xref_to_object->{$a}; # e.g. "Translation|1234"
     my $key_b = $xref_to_object->{$b};
     my ($type_a, $object_a) = split(/\|/, $key_a);
     my ($type_b, $object_b) = split(/\|/, $key_b);

     return 0 if ($type_a != $type_b); # only compare like with like

     my $query_identity_a = $object_xref_identities{$object_a}->{$a}->{"query_identity"};
     my $query_identity_b = $object_xref_identities{$object_b}->{$b}->{"query_identity"};

     return ($query_identity_a <=> $query_identity_b) if ($query_identity_a != $query_identity_b);

     my $target_identity_a = $object_xref_identities{$object_a}->{$a}->{"target_identity"};
     my $target_identity_b = $object_xref_identities{$object_b}->{$b}->{"target_identity"};

     return ($target_identity_a <=> $target_identity_b);

   } elsif ($src_a eq "Uniprot/SPTREMBL") {

     # Compare on words
     my $wrd_idx_a = find_match($xref_descriptions{$a}, @words);
     my $wrd_idx_b = find_match($xref_descriptions{$b}, @words);
     return $wrd_idx_a <=> $wrd_idx_b;

   } else {

     return 0;

   }
    return 0;

  } else {

    return $pos_a <=> $pos_b;

  }
}

# load external_db (if it's empty) from ../external_db/external_dbs.txt

sub upload_external_db {

  my $row = @{$core_dbi->selectall_arrayref("SELECT COUNT(*) FROM external_db")}[0];
  my $count = @{$row}[0];

  if ($count == 0) {
    my $edb = cwd() . "/../external_db/external_dbs.txt";
    print "external_db table is empty, uploading from $edb\n";
    my $edb_sth = $core_dbi->prepare("LOAD DATA INFILE \'$edb\' INTO TABLE external_db");
    $edb_sth->execute();
  } else {
    print "external_db table already has $count rows, will not change it\n";
   }

}

1;
