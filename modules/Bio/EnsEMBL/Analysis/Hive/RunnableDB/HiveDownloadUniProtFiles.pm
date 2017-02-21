#!/usr/bin/env perl

# Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
# Copyright [2016-2017] EMBL-European Bioinformatics Institute
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

package Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveDownloadUniProtFiles;

use strict;
use warnings;
use feature 'say';

use File::Spec::Functions qw(catfile);
use File::Path qw(make_path);

use parent ('Bio::EnsEMBL::Analysis::Hive::RunnableDB::HiveBaseRunnableDB');

sub param_defaults {
  my ($self) = @_;

  return {
    %{$self->SUPER::param_defaults},
    base_url => '"http://www.uniprot.org/uniprot/?query=',
  }
}

sub fetch_input {
  my $self = shift;

  if ($self->param_is_defined('query_url')) {
    my $url = $self->param('query_url');
    if ($url !~ /http|ftp/) {
      $url = $self->param('base_url').$url;
      $url .= '"' unless ($url =~ /"$/);
    }
    $self->param('query_url', [{url => $url, file_name => $self->param_required('filename')}]);
  }
  else {
    if($self->param('multi_query_download')) {
      my @urls;
      foreach my $hash (values %{$self->param('multi_query_download')}) {
        push(@urls, $self->build_query($hash));
      }
      $self->param('query_url', \@urls);
    }
    else {
      my %hash = (
        dest_dir => $self->param_required('dest_dir'),
        file_name => $self->param_required('file_name'),
        pe_level => $self->param_required('pe_level'),
      );
      $hash{compress} = $self->param('compress') if ($self->param_is_defined('compress'));
      $hash{taxon_group} = $self->param('taxon_group') if ($self->param_is_defined('taxon_group'));
      $hash{taxon_id} = $self->param('taxon_id') if ($self->param_is_defined('taxon_id'));
      $hash{exclude_id} = $self->param('exclude_id') if ($self->param_is_defined('exclude_id'));
      $hash{exclude_group} = $self->param('exclude_group') if ($self->param_is_defined('exclude_group'));
      $hash{compress} = $self->param('compress') if ($self->param_is_defined('compress'));
      $hash{mito} = $self->param('mito') if ($self->param_is_defined('mito'));
      $hash{fragment} = $self->param('fragment') if ($self->param_is_defined('fragment'));
      $hash{format} = $self->param('format') if ($self->param_is_defined('format'));
      $self->param('query_url', [$self->build_query(\%hash)]);
    }
  }
  return 1;
}

sub run {
  my $self = shift;

  # This is a bit lazy, originally this was designed to work with a single query
  # but now I also want it to work with multiple files. I'm going to put that into
  # the if and the else will retain the original single file logic
  my @iids;
  foreach my $query (@{$self->param_required('query_url')}) {
    my $query_url = $query->{url};
    my $filename = $query->{file_name};
    say "Downloading:\n$query_url\n";

    my $get_cmd = 'wget -q -O - ';
    if(system("$get_cmd $query_url > $filename")) {
      $self->throw("The wget query ended in an non-zero exit code:\n'$query_url'\n");
    }

    if($filename =~ s/\.gz$//) {
      my $gunzip_command = "gunzip $filename.gz";
      if(system($gunzip_command)) {
        $self->throw("gunzip on file ended in an non-zero exit code:\n$gunzip_command\n");
      }
    }
    push(@iids, $filename);
  }
  $self->output(\@iids);
  say "Finished downloading UniProt files";
  return 1;
}

sub write_output {
  my $self = shift;

  my @iids = map {{iid => $_}} @{$self->output};
  $self->dataflow_output_id(\@iids, $self->param('_branch_to_flow_to'));
}


sub build_query {
  my ($self,$query_params) = @_;
  my $taxon_id = $query_params->{'taxon_id'};
  my $taxon_group = $query_params->{'taxon_group'};
  my $exclude_id = $query_params->{'exclude_id'};
  my $exclude_group = $query_params->{'exclude_group'};
  my $dest_dir = $query_params->{'dest_dir'};
  my $file_name = $query_params->{'file_name'};
  my $pe_level = $query_params->{'pe_level'};
  my $pe_string = "(";
  my $taxonomy_string = "";
  my $exclude_string = "";
  my $compress = "yes";
  my $fragment_string = "+AND+fragment:no";
  my $mito = "+NOT+organelle%3Amitochondrion";
  my $format = "fasta";

  if(exists($query_params->{'compress'})) {
    if($query_params->{'compress'} eq '0') {
      $compress = "no";
    }
  }

  if(exists($query_params->{'mito'})) {
    if($query_params->{'mito'}) {
      $mito = undef;
    }
  }

  if(exists($query_params->{'fragment'})) {
    if($query_params->{'fragment'}) {
      $fragment_string = "+AND+fragment:yes";
    }
  }

  if(exists($query_params->{'format'})) {
    $format = $query_params->{'format'};
  }

  # http://www.uniprot.org/uniprot/?query=existence%3A%22evidence+at+protein+level%22+OR+existence%3A%22evidence+at+transcript+level%22+AND+taxonomy%3A%22Mammalia+%5B40674%5D%22+NOT+taxonomy%3A%22Primates+%5B9443%5D%22&sort=score

  my $full_query = $self->param('base_url');
  my %pe_code = (
                  '1' => 'evidence+at+protein+level',
                  '2' => 'evidence+at+transcript+level',
                  '3' => 'inferred+from+homology',
                  '4' => 'predicted',
                  '5' => 'uncertain',
                );

  # Must have file_name, pe_level, dest_dir and either taxon_id or taxonomy
  unless($file_name && $dest_dir && ($taxon_id || $taxon_group) && $pe_level) {
    $self->throw("Must define the following keys:\nfile_name\ntaxon_id or taxonomy\ndest_dir\npe_level");
  }

  my @pe_array = @{$pe_level};
  unless(scalar(@pe_array)) {
    $self->throw("Not PE levels found in value of pe_levels key. Format should be an array ref: ['1,2']");
  }

  foreach my $pe_level (@pe_array) {
    unless($pe_level =~ /\d+/) {
     $self->throw("Could not parse a PE level from the following: ".$pe_level);
    }

    my $parsed_pe_level = $&;
    unless($parsed_pe_level >= 1 && $parsed_pe_level <= 5) {
     $self->throw("Parsed PE level is outside the normal range of 1-5: ".$parsed_pe_level);
   }
   $pe_string .= 'existence%3A%22'.$pe_code{$pe_level}.'%22+OR+';
  }

  $pe_string =~ s/\+OR\+$/\)/;

  # NOTE this bit of the code with taxonomy and exclude is shit and needs to be upgraded
  if($taxon_id) {
    $taxonomy_string = '+AND+taxonomy%3A+'.$taxon_id;
  } elsif($taxon_group) {
    $taxonomy_string = '+AND+taxonomy%3A'.$taxon_group;
  }

#+NOT+taxonomy%3A%22
  if($exclude_id) {
    my @exclusion_array = @{$exclude_id};
    foreach my $id_to_exclude (@exclusion_array) {
      $exclude_string .= '+NOT+taxonomy%3A+'.$id_to_exclude;
    }
  }

  $full_query .= $pe_string.$taxonomy_string.$exclude_string.$fragment_string.$mito.'&compress='.$compress.'&format='.$format.'"';
  if (!-d $query_params->{dest_dir}) {
    make_path($query_params->{dest_dir});
  }
  my $filename = catfile($query_params->{dest_dir}, $query_params->{file_name});
  $filename .= '.gz' if ($compress eq 'yes');;

  return {url => $full_query, file_name => $filename};
}

1;
