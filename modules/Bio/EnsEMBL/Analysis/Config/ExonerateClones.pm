#
# package Bio::EnsEMBL::Pipeline::Config::ExonerateTranscript
# 
# Cared for by EnsEMBL (ensembl-dev@ebi.ac.uk)
#
# Copyright GRL & EBI
#
# You may distribute this module under the same terms as perl itself

# POD documentation - main docs before the code

=head1 NAME

Bio::EnsEMBL::Pipeline::Config::Affy::Exonerate2Affy

=head1 SYNOPSIS

    use Bio::EnsEMBL::Pipeline::Config::Exonerate2Genes;

=head1 DESCRIPTION

This contains the configuration for the  alignment of clone
sequences (dna) against a genome (dna)
using exonerate. So this config looks very similar to that
of any other exonerate-driving config.

The layout of the configuration is a set of hashes,
each one keyed by logic name. There is also a DEFAULT hash,
which is used as the default for all logic names (this
was the configuration pattern stolen from Exonerate2Genes,
although in this case it's very unlikely you will need to have
different configs by logic name).

=head1 CONTACT

=cut


package Bio::EnsEMBL::Analysis::Config::ExonerateClones;

use strict;
use vars qw( %Config );

%Config = (
  CLONE_CONFIG => {
    DEFAULT => {

      # path to softmasked, dusted sequence on the farm 
      # 
      
      GENOMICSEQS         => '/data/blastdb/Ensembl/Human/NCBI35/softmasked_dusted', #allowed to be a dir.
      QUERYTYPE           => 'dna',

      # must be a single file containing all clone fasta sequences

      QUERYSEQS           => '/ecs2/scratch2/jb16/sheep/sheep_clones.fa',

      # must supply one, since the queryseqs MUST be a single file 
      IIDREGEXP           => '(\d+):(\d+)',
      DNADB => {
        -dbname => 'homo_sapiens_core_36_35i',
        -host => 'ecs2',
        -port => '3364',
        -user => 'ensro',
        -pass => '',
        },
      OUTDB => {
        -dbname => 'jb16_sheep_human',
        -host => 'ia64g',
        -port => '3306',
        -user => 'ensadmin',
        -pass => 'ensro',
        },
      OPTIONS             => ' --bestn 10 --dnahspthreshold 75 --fsmmemory 256 --dnawordlen 12 --dnawordthreshold 5 --forwardcoordinates FALSE --softmasktarget TRUE --exhaustive FALSE --score 100 --saturatethreshold 10 ',
    },
  }
);

sub import {
  my ($callpack) = caller(0); # Name of the calling package
  my $pack = shift; # Need to move package off @_

  # Get list of variables supplied, or else everything
  my @vars = @_ ? @_ : keys( %Config );
  return unless @vars;
  
  # Predeclare global variables in calling package
  eval "package $callpack; use vars qw("
    . join(' ', map { '$'.$_ } @vars) . ")";
    die $@ if $@;


    foreach (@vars) {
	if ( defined $Config{$_} ) {
            no strict 'refs';
	    # Exporter does a similar job to the following
	    # statement, but for function names, not
	    # scalar variables:
	    *{"${callpack}::$_"} = \$Config{ $_ };
	} else {
	    die "Error: Config: $_ not known\n";
	}
    }
}

1;
