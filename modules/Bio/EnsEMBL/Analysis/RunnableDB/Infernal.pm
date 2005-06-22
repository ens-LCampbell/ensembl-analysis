# You may distribute this module under the same terms as perl itself
#
# POD documentation - main docs before the code

=pod 

=head1 NAME

Bio::EnsEMBL::Analysis::RunnableDB::Infernal;


=head1 SYNOPSIS

    my $runnableDB = Bio::EnsEMBL::Analysis::RunnableDB::Infernal->new(
            	-db       => $db_adaptor,
		-input_id => $flag_id,		
		-analysis => $analysis,
	        );
    $runnabledb->fetch_input();
    $runnabledb->run();
    $runnabledb->write_output();


=head1 DESCRIPTION

RunnableDB to wrap cmsearch - part of the Infernal suite of programs by Sean Eddy.
Uses RFAM blast hits to identify regions where cmsearch should be run. Blast hits
are run using the RfamBlast module and then are filtered on a familly by familly basis.
Blast hits that look promising are flagged by predict_ncRNAs.pl and the flags are used
as input_ids.
Uses the Bio::EnsEMBL::Analysis::Config::Databases config file. Writes non coding genes to 
the $GB_FINALDB database and gets DNA from $GB_ database. The blast hits from BlastRfam are
stored in the pipeline database;
Creates single exon non-coding genes with gene descriptions obtained from Rfam.descriptions
file. The dna align feature representing the initial blast hit is added as a supporting feature
and the RNA secondary structure predicted by Infernal is added as a transcript attribute
in a length encoded string form to take up less room in the db.

=head1 CONTACT

Post questions to the Ensembl development list: ensembl-dev@ebi.ac.uk

=cut

package Bio::EnsEMBL::Analysis::RunnableDB::Infernal;

use Bio::EnsEMBL::Pipeline::DBSQL::FlagAdaptor;
use Bio::EnsEMBL::Analysis::RunnableDB;
use Bio::Seq;
use Bio::EnsEMBL::Analysis::Runnable::Infernal;
use Bio::EnsEMBL::Analysis::Config::Databases;
use strict;
use warnings;

use vars qw(@ISA);

@ISA = qw(Bio::EnsEMBL::Analysis::RunnableDB);

my $runnable;

=head2 fetch_input

  Title   :   fetch_input
  Usage   :   $self->fetch_input
  Function:   Opens connections to the final gene build database to store the genes in.
          :   Also opens connection to the genebuild DNA database to fetch DNA from.
          :   Parses flags use as input_ids and fetches dna_align_features to run cmsearch
          :   on.
  Returns :   none
  Args    :   none

=cut

sub fetch_input{
  my ($self)=@_;
  # open connection to genes database
  my $genes_db = new Bio::EnsEMBL::DBSQL::DBAdaptor
    (
     '-host'   => $GB_FINALDBHOST,
     '-user'   => $GB_FINALDBUSER,
     '-dbname' => $GB_FINALDBNAME,
     '-pass'   => $GB_FINALDBPASS,
     '-port'   => $GB_FINALDBPORT,
    );
  $self->gene_db($genes_db);
  my $dna_db = new Bio::EnsEMBL::DBSQL::DBAdaptor
    (
     '-host'   => $GB_DBHOST,
     '-user'   => $GB_DBUSER,
     '-dbname' => $GB_DBNAME,
     '-pass'   => $GB_DBPASS,
     '-port'   => $GB_DBPORT,
    );
  #add dna_db
  $self->db->dnadb($dna_db);

  my ($start,$end);
  my (@dafs,@queries);
  my $padding = 200;
  my $fa = Bio::EnsEMBL::Pipeline::DBSQL::FlagAdaptor->new($self->db);
  my $dafa = $self->db->get_DnaAlignFeatureAdaptor;
  my $sa = $self->db->get_SliceAdaptor;
  my $runname = "Bio::EnsEMBL::Analysis::Runnable::Infernal";
  if ($self->input_id =~ /(\d+):(\d+)/) {
    $start = $1;
    $end = $2;
  } else {
    $self->throw("Input id not recognised\n");
  }
 # get ids
  for (my $i = $start ; $i <= $end ; $i++){
    my $flag;
    # try and fetch it
    eval{
      $flag = $fa->fetch_by_dbID($i);
    };
    if ($flag && $flag->goalAnalysis->logic_name eq $self->analysis->logic_name){
      my $daf = $dafa->fetch_by_dbID($flag->ensembl_id);
      push @dafs, $daf;
    }
  }

    # Make  the runnable
    my $runnable = $runname->new
      (
       -queries  => \@dafs,
       -analysis => $self->analysis,
       -program => $self->analysis->program_file
      );
    $self->runnable($runnable);
}

=head2 run

  Args       : none
  Description: Runs the runnable.
  Exceptions : Throws if the the runnable module is not set
  Returntype : scalar

=cut

sub run{
  my ($self) = @_;
  foreach my $runnable (@{$self->runnable}) {
    $self->throw("Runnable module not set") unless ($runnable->isa("Bio::EnsEMBL::Analysis::Runnable"));
    $runnable->run();
    $self->output($runnable->output);
  }
}

=head2 write_output

  Args       : none
  Description: Writes the single exon ncRNA genes into the final genebuild databse, 
             : also stores the structure attribute associated with the transcript
  Exceptions : Throws if gene or transcript attribute fail to write to the database
  Returntype : scalar

=cut

sub write_output{
  my ($self) = @_;
  my $adaptor = $self->gene_db->get_GeneAdaptor;
  my $aa = $self->gene_db->get_AttributeAdaptor;
  my $dbea = $self->gene_db->get_DBEntryAdaptor;
  my @attributes;
  my $xref;
  foreach my $gene_hash (@{$self->output}){    
    my $gene = $gene_hash->{'gene'};
    @attributes = @{$gene_hash->{'attrib'}};
    $xref = $gene_hash->{'xref'};
    $gene->analysis($self->analysis);
    $gene->slice($self->query) if(!$gene->slice);
    $self->feature_factory->validate($gene);

    eval{
      $adaptor->store($gene);
    };
    if($@){
      $self->throw("Infernal:store failed, failed to write ".$gene." to ".
		   "the database $@");
    }
    foreach my $trans (@{$gene->get_all_Transcripts}){
      eval{
	$aa->store_on_Transcript($trans,\@attributes);
	$dbea->store($xref, $trans->dbID, 'Transcript') if $xref;
	$trans->display_xref($xref);
	$gene->display_xref($xref);
	$self->gene_db->get_TranscriptAdaptor->update($trans);
	$self->gene_db->get_GeneAdaptor->update($gene);	
      };
      if($@){
	$self->throw("Infernal:store failed, failed to write xrefs or attributes  on transcript ".
		     $trans." in the database $@");
      }
    }
  }
  return 1;
}

#########################################################
# Containers

=head2 gene_db

  Arg [1]    : Bio::EnsEMBL::DBSQL::DBAdaptor
  Description: get/set gene db adaptor
  Returntype : Bio::EnsEMBL::DBSQL::DBAdaptor
  Exceptions : none
  Caller     : general

=cut

sub gene_db {
  my ($self, $gene_db) = @_;
  if ($gene_db){
    unless ($gene_db->isa("Bio::EnsEMBL::DBSQL::DBAdaptor")){
      $self->throw("gene db is not a Bio::EnsEMBL::DBSQL::DBAdaptor, it is a $gene_db");
    }
    $self->{'_gene_db'} = $gene_db;
  }
  return $self->{'_gene_db'};
}



1;
