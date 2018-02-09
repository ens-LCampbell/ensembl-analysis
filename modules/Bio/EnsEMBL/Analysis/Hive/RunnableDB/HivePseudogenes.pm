=head1 LICENSE

# Copyright [1999-2016] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#      http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


=head1 CONTACT

  Please email comments or questions to the public Ensembl
  developers list at <http://lists.ensembl.org/mailman/listinfo/dev>.

  Questions may also be sent to the Ensembl help desk at
  <http://www.ensembl.org/Help/Contact>.

=cut

=head1 NAME

Bio::EnsEMBL::Analysis::RunnableDB::Pseudogene_DB - 

=head1 SYNOPSIS

my $runnabledb = Bio::EnsEMBL::Analysis::RunnableDB::Pseudogene_DB->new(
						-db => $db_adaptor,
						-input_id => $slice_id,		
					        -analysis => $analysis,
								       );

$runnabledb->fetch_input();
$runnabledb->run();
my @array = @{$runnabledb->output};
$runnabledb->write_output();

=head1 DESCRIPTION

This object wraps Bio::EnsEMBL::Analysis::Runnable::Pseudogene.pm 

Opens connections to 2 dbs:
1 for repeat sequences (GB_DB)
1 for fetching genes from (GB_FINAL)

fetches all the genes on the slice, all the repeats associated with each gene and 
collects alignment feature evidence for single exon genes and passes them to the 
runnable.

This module forms the base class of the pseudogene analysis for the gene build.
It will identify obvious pseudogenes but will also flag genes that look
interesting for analysis by either:
Bio::EnsEMBL::Analysis::RunnableDB::Spliced_elsewhere or
Bio::EnsEMBL::Analysis::RunnableDB::PSILC
PSILC will work on any gene with a PFAM domain and will attempt to predict if
it is a pseudogene - it underpredicts pseudogenes but is useful for sequences
that look dodgy but have no overt evidence of being pseudogenes.
Spliced_elsewhere tests for retrotransposition and tends to be run over single
exon genes.
Configuration for all three of these modules is here:
Bio::EnsEMBL::Analysis::Config::Pseudogene


=head1 METHODS


=head1 APPENDIX


=cut

package Bio::EnsEMBL::Analysis::Hive::RunnableDB::HivePseudogenes;

use strict;
use warnings;
use feature 'say';
use Data::Dumper;

use Bio::EnsEMBL::Analysis::Tools::GeneBuildUtils::GeneUtils;
use Bio::EnsEMBL::Analysis::Runnable::Pseudogene;
use Bio::EnsEMBL::DBSQL::DBConnection;
use Bio::EnsEMBL::Utils::Argument qw( rearrange );
use parent ('Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveBaseRunnableDB');

our @EXPORT_OK = qw(_remove_transcript_from_gene);

=head2 fetch_input

  Title   :   fetch_input
  Usage   :   $self->fetch_input
  Function:   Fetches input data for Pseudogene.pm from the database
  Returns :   none
  Args    :   none

=cut

sub fetch_input {
  my ($self) = @_;

  $self->create_analysis;

  unless(-e $self->PS_MULTI_EXON_DIR) {
    system("mkdir -p ".$self->PS_MULTI_EXON_DIR);
  }
  my $input_dba = $self->hrdb_get_dba($self->param('input_gene_db'));
  my $repeat_dba = $self->hrdb_get_dba($self->param('repeat_db'));
  my $output_dba = $self->hrdb_get_dba($self->param('output_db'));
  my $dna_dba = $self->hrdb_get_dba($self->param('dna_db'));

  if($dna_dba) {
    $input_dba->dnadb($dna_dba);
    $repeat_dba->dnadb($dna_dba);
    $output_dba->dnadb($dna_dba);
  }

  $self->hrdb_set_con($input_dba,'input_gene_db');
  $self->hrdb_set_con($repeat_dba,'repeat_db');
  $self->hrdb_set_con($output_dba,'output_db');

#  my $results = [];    # array ref to store the output
  my $repeat_blocks;
#  my %homolog_hash;
#  my @transferred_genes;

  my $repeat_slice_adaptor = $repeat_dba->get_SliceAdaptor;
  my $gene_id = $self->param('iid');
  my $gene_adaptor = $input_dba->get_GeneAdaptor;
  my $gene = $gene_adaptor->fetch_by_dbID($gene_id);
  my $gene_slice = $gene->slice();

  # due to offset with repeat features
  my $toplevel_slice = $repeat_slice_adaptor->fetch_by_region( 'toplevel', $gene_slice->seq_region_name);
  my $transferred_gene = $gene->transfer($toplevel_slice);
  my $repeat_slice = $repeat_slice_adaptor->fetch_by_region('toplevel', $gene_slice->seq_region_name,$transferred_gene->start,$transferred_gene->end);

  say "Repeat slice name: ".$repeat_slice->name;

  $self->query($gene_slice);
  my @feats = @{$repeat_slice->get_all_RepeatFeatures};
  @feats = map { $_->transfer($toplevel_slice) } @feats;
  my $blocks = $self->get_all_repeat_blocks(\@feats);
  # make hash of repeat blocks using the gene as the key
  $repeat_blocks->{$transferred_gene} = $blocks;

  $self->genes([$transferred_gene]);
  $self->repeat_blocks($repeat_blocks);
  $self->make_runnable;

  return 1;
} ## end sub fetch_input


sub make_runnable {
  my ($self) = @_;

  my $runnable =
    Bio::EnsEMBL::Analysis::Runnable::Pseudogene->new(
           -analysis                    => $self->analysis,
           -genes                       => $self->genes,
           -repeat_features             => $self->repeat_blocks,
           -PS_REPEAT_TYPES             => $self->PS_REPEAT_TYPES,
           -PS_FRAMESHIFT_INTRON_LENGTH => $self->PS_FRAMESHIFT_INTRON_LENGTH,
           -PS_MAX_INTRON_LENGTH        => $self->PS_MAX_INTRON_LENGTH,
           -PS_MAX_INTRON_COVERAGE      => $self->PS_MAX_INTRON_COVERAGE,
           -PS_MAX_EXON_COVERAGE        => $self->PS_MAX_EXON_COVERAGE,
           -PS_NUM_FRAMESHIFT_INTRONS   => $self->PS_NUM_FRAMESHIFT_INTRONS,
           -PS_NUM_REAL_INTRONS         => $self->PS_NUM_REAL_INTRONS,
           -SINGLE_EXON                 => $self->SINGLE_EXON,
           -INDETERMINATE               => $self->INDETERMINATE,
           -PS_MIN_EXONS                => $self->PS_MIN_EXONS,
           -PS_MULTI_EXON_DIR           => $self->PS_MULTI_EXON_DIR,
           -BLESSED_BIOTYPES            => $self->BLESSED_BIOTYPES,
           -PS_PSEUDO_TYPE              => $self->PS_PSEUDO_TYPE,
           -KEEP_TRANS_BIOTYPE          => $self->KEEP_TRANS_BIOTYPE,
           -PS_BIOTYPE                  => $self->PS_BIOTYPE,
           -PS_REPEAT_TYPE              => $self->PS_REPEAT_TYPE,
           -DEBUG                       => $self->DEBUG,);
  $self->runnable($runnable);
} ## end sub make_runnable


=head2 get_all_repeat_blocks

  Args       : none
  Description: merges repeats into blocks for each gene
  Returntype : array of Seq_Feature blocks;

=cut 

sub get_all_repeat_blocks {
  my ( $self, $repeat_ref ) = @_;
  my @repeat_blocks;
  my @repeats = @{$repeat_ref};
  @repeats = sort { $a->start <=> $b->start } @repeats;
  my $curblock = undef;

REPLOOP: foreach my $repeat (@repeats) {
    my $rc  = $repeat->repeat_consensus;
    my $use = 0;
    foreach my $type ( @{ $self->PS_REPEAT_TYPES } ) {
      if ( $rc->repeat_class =~ /$type/ ) {
        $use = 1;
        last;
      }
    }
    next REPLOOP unless $use;
    if ( $repeat->start <= 0 ) {
      $repeat->start(1);
    }
    if ( defined($curblock) && $curblock->end >= $repeat->start ) {
      if ( $repeat->end > $curblock->end ) {
        $curblock->end( $repeat->end );
      }
    } else {
      $curblock =
        Bio::EnsEMBL::Feature->new( -START  => $repeat->start,
                                    -END    => $repeat->end,
                                    -STRAND => $repeat->strand,
                                    -SLICE => $repeat->slice );
      push( @repeat_blocks, $curblock );
    }
  } ## end foreach my $repeat (@repeats)
  @repeat_blocks = sort { $a->start <=> $b->start } @repeat_blocks;
  return \@repeat_blocks;
} ## end sub get_all_repeat_blocks

=head2 write_output

  Args       : none
  description: writes gene array into db specified in Bio::EnsEMBL::Config::GeneBuild::Databases.pm
  exception  : warns if it cannot write gene
  Returntype : none

=cut 


sub write_output {
  my ($self) = @_;
  my $genes = $self->output;

  my %feature_hash;
  # write genes out to a different database from the one we read genes from.
  my $out_dba = $self->hrdb_get_con('output_db');

  my $gene_adaptor = $out_dba->get_GeneAdaptor;
  foreach my $gene ( @{$genes} ) {
    empty_Gene($gene);
    $gene_adaptor->store($gene);
  }

  my $spliced_elsewhere_ids = $self->spliced_elsewhere_ids();
  if($spliced_elsewhere_ids) {
    foreach my $id (@{$spliced_elsewhere_ids}) {
      my $output_hash = {};
      $output_hash->{'iid'} = $id;
      $self->dataflow_output_id($output_hash,2);
    }
  }

  return 1;
} ## end sub write_output


=head2 run

  Args       : none
  Description: overrides runnableDb run method to allow gene objects to be validated 
before runnning the runnable
  Returntype : scalar

=cut 

sub run {
  my ($self) = @_;
  foreach my $runnable ( @{ $self->runnable } ) {
    unless($runnable->isa("Bio::EnsEMBL::Analysis::Runnable")) {
      $self->throw("Runnable module not set");
    }

    $runnable->run();
    $self->output($runnable->output);
    if($self->SINGLE_EXON) {
      $self->spliced_elsewhere_ids($runnable->single_exon_genes);
    }
#    if($self->INDETERMINATE) {
#      $self->store_ids( $runnable->indeterminate_genes, $self->PSILC_LOGIC_NAME );
#    }
  }
  return 1;
}

=head2 store_ids

Arg [none] :
  Description: stores gene dbIDS of genes being held back for further analyses
  Returntype : scalar
  Exceptions : throws if it cannot open the file
  Caller     : general

=cut

#sub store_ids {
#  my ($self, $id_list,$analysis_name) = @_;

#  my $flag_adaptor = Bio::EnsEMBL::Pipeline::DBSQL::FlagAdaptor->new($self->hrdb_get_con('output_db'));
#  my $analysis = $self->analysis();

  # What do you do if the analysis thing isnt found?
#  return 0 unless (scalar(@{$id_list} >0));
#  foreach my $id(@{$id_list}){
#    my $flag = Bio::EnsEMBL::Pipeline::Flag->new(
#						 '-type'         => 'gene',
#						 '-ensembl_id'   => $id,
#						 '-goalAnalysis' => $analysis,
#						);
#    $flag_adaptor->store($flag);
#  }
#  return;
#}

=head2 lazy_load

  Arg [1]    : Bio::EnsEMBL::Gene
  Description: forces lazy loading of transcripts etc.s
  Returntype : Bio::EnsEMBL::Gene
  Exceptions : none
  Caller     : general

=cut

sub lazy_load {
  my ($self, $gene) = @_;
  if ($gene){
    unless ($gene->isa("Bio::EnsEMBL::Gene")){
      throw("gene is not a Bio::EnsEMBL::Gene, it is a $gene");
    }
    foreach my $trans(@{$gene->get_all_Transcripts}){
      my $transl = $trans->translation; 
       $trans->get_all_supporting_features() ; 
      if ($transl){
	$transl->get_all_ProteinFeatures;
      }
    }
  }
  return $gene;
}

=head2 _remove_transcript_from_gene

  Args       : Bio::EnsEMBL::Gene object , Bio::EnsEMBL::Transcript object
  Description: steves method for removing unwanted transcripts from genes
  Returntype : scalar

=cut 

sub _remove_transcript_from_gene {
  my ($self, $gene, $trans_to_del)  = @_;
  # check to see if it is a blessed transcript first
  return 'BLESSED' if $self->BLESSED_BIOTYPES->{$trans_to_del->biotype};
  my @newtrans;
  foreach my $trans (@{$gene->get_all_Transcripts}) {
    if ($trans != $trans_to_del) {
      push @newtrans,$trans;
    }
  }

  # The naughty bit!
  $gene->{_transcript_array} = [];

  foreach my $trans (@newtrans) {
    $gene->add_Transcript($trans);
  }

  return;
}

=head2 transcript_to_keep

  Args       : Bio::EnsEMBL::Transcript object
  Description: removes the translation provided it is not a blessed transcript
  Returntype : scalar

=cut 


sub transcript_to_keep {
  my ($self, $trans_to_keep)  = @_;
  return if  $self->BLESSED_BIOTYPES->{$trans_to_keep->biotype};
  $trans_to_keep->translation(undef);
  return;
}


=head2 genes

  Arg [1]    : array ref
  Description: get/set genescript set to run over
  Returntype : array ref to Bio::EnsEMBL::Gene objects
  Exceptions : throws if not a Bio::EnsEMBL::Gene
  Caller     : general

=cut

sub genes {
  my ($self, $genes) = @_;
  if ($genes) {
    foreach my $gene (@{$genes}) {
      unless  ($gene->isa("Bio::EnsEMBL::Gene")){
	$self->throw("Input isn't a Bio::EnsEMBL::Gene, it is a $gene\n$@");
      }
    }
    $self->param('_genes',$genes);
  }
  return $self->param('_genes');
}


=head2 repeat_blocks

  Arg [1]    : array ref
  Description: get/set genescript set to run over

=cut

sub repeat_blocks {
  my ($self, $val) = @_;

  if (defined $val) {
    $self->param('_repeat_blocks',$val);
  }
  return $self->param('_repeat_blocks');
}



=head2 pseudo_genes

  Arg [1]    : Bio::EnsEMBL::Gene
  Description: get/set for pseudogenes 
  Returntype : Bio::EnsEMBL::Gene
  Exceptions : none
  Caller     : general

=cut

sub pseudo_genes {
  my ($self, $pseudo_gene) = @_;
  if ($pseudo_gene) {
    unless ($pseudo_gene->isa("Bio::EnsEMBL::Gene")){
      $self->throw("pseudo gene is not a Bio::EnsEMBL::Gene, it is a $pseudo_gene");
    }
    push @{$self->param('_pseudo_gene')},$self->lazy_load($pseudo_gene);
  }
  return $self->param('_pseudo_gene');
}

=head2 real_genes

Arg [1]    : Bio::EnsEMBL::Gene
 Description: get/set for 'functional' genes
  Returntype : Bio::EnsEMBL::Gene
  Exceptions : none
  Caller     : general

=cut

sub real_genes {
  my ($self, $real_gene) = @_;
  if ($real_gene) {
    unless ($real_gene->isa("Bio::EnsEMBL::Gene")){
      $self->throw("real gene is not a Bio::EnsEMBL::Gene, it is a $real_gene");
    }
    push @{$self->param('_real_gene')},$self->lazy_load($real_gene);
  }
  return $self->param('_real_gene');
}


=head2 ignored_genes

Arg [1]    : Bio::EnsEMBL::Gene
 Description: get/set for genes that pseudogene does not check
  Returntype : Bio::EnsEMBL::Gene
  Exceptions : none
  Caller     : general

=cut

sub ignored_genes {
  my ($self, $ignored_gene) = @_;
  if ($ignored_gene) {
    unless ($ignored_gene->isa("Bio::EnsEMBL::Gene")){
      $self->throw("ignored gene is not a Bio::EnsEMBL::Gene, it is a $ignored_gene");
    }
    push @{$self->param('_ignored_gene')},$self->lazy_load($ignored_gene);
  }
  return $self->param('_ignored_gene');
}


sub spliced_elsewhere_ids {
  my ($self, $spliced_elsewhere_genes) = @_;
  unless($self->param_is_defined('_spliced_elsewhere_ids')) {
    $self->param('_spliced_elsewhere_ids',[]);
  }

  if($spliced_elsewhere_genes) {
    foreach my $dbID (@{$spliced_elsewhere_genes}) {
      push @{$self->param('_spliced_elsewhere_ids')},$dbID;
    }
  }
  return $self->param('_spliced_elsewhere_ids');
}

#==================================================================

sub PS_INPUT_DATABASE{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PS_INPUT_DATABASE',$arg);
  }
  return $self->param('PS_INPUT_DATABASE');
}

sub PS_OUTPUT_DATABASE {
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PS_OUTPUT_DATABASE',$arg);
  }
  return $self->param('PS_OUTPUT_DATABASE');
}

sub PS_FRAMESHIFT_INTRON_LENGTH{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PS_FRAMESHIFT_INTRON_LENGTH',$arg);
  }
  return $self->param('PS_FRAMESHIFT_INTRON_LENGTH');
}

sub PS_MAX_INTRON_LENGTH{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PS_MAX_INTRON_LENGTH',$arg);
  }
  return $self->param('PS_MAX_INTRON_LENGTH');
}

sub PS_REPEAT_TYPES{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PS_REPEAT_TYPES',$arg);
  }
  return $self->param('PS_REPEAT_TYPES');
}

sub PS_MAX_INTRON_COVERAGE{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PS_MAX_INTRON_COVERAGE',$arg);
  }
  return $self->param('PS_MAX_INTRON_COVERAGE');
}


sub PS_MAX_EXON_COVERAGE{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PS_MAX_EXON_COVERAGE',$arg);
  }
  return $self->param('PS_MAX_EXON_COVERAGE');
}

sub PS_NUM_FRAMESHIFT_INTRONS {
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PS_NUM_FRAMESHIFT_INTRONS',$arg);
  }
  return $self->param('PS_NUM_FRAMESHIFT_INTRONS');
}

sub PS_NUM_REAL_INTRONS{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PS_NUM_REAL_INTRONS',$arg);
  }
  return $self->param('PS_NUM_REAL_INTRONS');
}

sub PS_BIOTYPE{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PS_BIOTYPE',$arg);
  }
  return $self->param('PS_BIOTYPE');
}


sub PS_PERCENT_ID_CUTOFF{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PS_PERCENT_ID_CUTOFF',$arg);
  }
  return $self->param('PS_PERCENT_ID_CUTOFF');
}


sub PS_P_VALUE_CUTOFF{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PS_P_VALUE_CUTOFF',$arg);
  }
  return $self->param('PS_P_VALUE_CUTOFF');
}


sub PS_RETOTRANSPOSED_COVERAGE{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PS_RETOTRANSPOSED_COVERAGE',$arg);
  }
  return $self->param('PS_RETOTRANSPOSED_COVERAGE');
}


sub PS_ALIGNED_GENOMIC{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PS_ALIGNED_GENOMIC',$arg);
  }
  return $self->param('PS_ALIGNED_GENOMIC');
}


sub PS_PSEUDO_TYPE{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PS_PSEUDO_TYPE',$arg);
  }
  return $self->param('PS_PSEUDO_TYPE');
}



sub SINGLE_EXON{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('SINGLE_EXON',$arg);
  }
  return $self->param('SINGLE_EXON');
}


sub INDETERMINATE{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('INDETERMINATE',$arg);
  }
  return $self->param('INDETERMINATE');
}


sub RETROTRANSPOSED{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('RETROTRANSPOSED',$arg);
  }
  return $self->param('RETROTRANSPOSED');
}


sub RETRO_TYPE{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('RETRO_TYPE',$arg);
  }
  return $self->param('RETRO_TYPE');
}


sub SPLICED_ELSEWHERE_LOGIC_NAME{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('SPLICED_ELSEWHERE_LOGIC_NAME',$arg);
  }
  return $self->param('SPLICED_ELSEWHERE_LOGIC_NAME');
}

sub PSILC_LOGIC_NAME{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PSILC_LOGIC_NAME',$arg);
  }
  return $self->param('PSILC_LOGIC_NAME');
}

sub PS_SPAN_RATIO{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PS_SPAN_RATIO',$arg);
  }
  return $self->param('PS_SPAN_RATIO');
}

sub PS_MIN_EXONS{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PS_MIN_EXONS',$arg);
  }
  return $self->param('PS_MIN_EXONS');
}


sub PS_MULTI_EXON_DIR{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PS_MULTI_EXON_DIR',$arg);
  }
  return $self->param('PS_MULTI_EXON_DIR');
}

sub PS_CHUNK{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PS_CHUNK',$arg);
  }
  return $self->param('PS_CHUNK');
}

sub DEBUG{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('DEBUG',$arg);
  }
  return $self->param('DEBUG');
}

sub SUBJECT{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('SUBJECT',$arg);
  }
  return $self->param('SUBJECT');
}

sub PSILC_SUBJECT_DBNAME{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PSILC_SUBJECT_DBNAME',$arg);
  }
  return $self->param('PSILC_SUBJECT_DBNAME');
}

sub PSILC_SUBJECT_DBHOST{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PSILC_SUBJECT_DBHOST',$arg);
  }
  return $self->param('PSILC_SUBJECT_DBHOST');
}

sub PSILC_SUBJECT_DBPORT{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PSILC_SUBJECT_DBPORT',$arg);
  }
  return $self->param('PSILC_SUBJECT_DBPORT');
}

sub ORTH1{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('ORTH1',$arg);
  }
  return $self->param('ORTH1');
}



sub PSILC_ORTH1_DBNAME{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PSILC_ORTH1_DBNAME',$arg);
  }
  return $self->param('PSILC_ORTH1_DBNAME');
}

sub PSILC_ORTH1_DBHOST{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PSILC_ORTH1_DBHOST',$arg);
  }
  return $self->param('PSILC_ORTH1_DBHOST');
}

sub PSILC_ORTH1_DBPORT{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PSILC_ORTH1_DBPORT',$arg);
  }
  return $self->param('PSILC_ORTH1_DBPORT');
}

sub ORTH2{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('ORTH2',$arg);
  }
  return $self->param('ORTH2');
}

sub PSILC_ORTH2_DBNAME{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PSILC_ORTH2_DBNAME',$arg);
  }
  return $self->param('PSILC_ORTH2_DBNAME');
}

sub PSILC_ORTH2_DBHOST{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PSILC_ORTH2_DBHOST',$arg);
  }
  return $self->param('PSILC_ORTH2_DBHOST');
}

sub PSILC_ORTH2_DBPORT{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PSILC_ORTH2_DBPORT',$arg);
  }
  return $self->param('PSILC_ORTH2_DBPORT');
}

sub PSILC_WORK_DIR{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PSILC_WORK_DIR',$arg);
  }
  return $self->param('PSILC_WORK_DIR');
}

sub PS_SPECIES_LIMIT{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PS_SPECIES_LIMIT',$arg);
  }
  return $self->param('PS_SPECIES_LIMIT');
}

sub PSILC_BLAST_DB{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PSILC_BLAST_DB',$arg);
  }
  return $self->param('PSILC_BLAST_DB');
}

sub PSILC_CHUNK{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PSILC_CHUNK',$arg);
  }
  return $self->param('PSILC_CHUNK');
}

sub REP_TRANSCRIPT{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('REP_TRANSCRIPT',$arg);
  }
  return $self->param('REP_TRANSCRIPT');
}

sub PS_REPEAT_TYPE{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('PS_REPEAT_TYPE',$arg);
  }
  return $self->param('PS_REPEAT_TYPE');
}
						
sub BLESSED_BIOTYPES{
  my ($self, $arg) = @_;
  if($arg){
    $self->param('BLESSED_BIOTYPES',$arg);
  }
  return $self->param('BLESSED_BIOTYPES');
}
sub KEEP_TRANS_BIOTYPE{
  my ($self, $arg) = @_;
  if(defined $arg){
    $self->param('KEEP_TRANS_BIOTYPE',$arg);
  }
  return $self->param('KEEP_TRANS_BIOTYPE');
}

1;
