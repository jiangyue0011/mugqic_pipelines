#!/usr/bin/perl

=head1 NAME

I<validation>

=head1 SYNOPSIS

validation.pl

=head1 DESCRIPTION

B<validation> Is the SNV/Indel validation pipeline

=head1 AUTHOR

B<Louis Letourneau> - I<louis.letourneau@mail.mcgill.ca>

=head1 DEPENDENCY

B<Pod::Usage> Usage and help output.

B<Data::Dumper> Used to debbug

B<Config::Simple> Used to parse config file

B<File::Basename> path parsing

B<Cwd> path parsing

=cut

# Strict Pragmas
#---------------------
use strict;
use warnings;
#---------------------

BEGIN{
    #Makesure we can find the GetConfig::LoadModules module relative to this script install
    use File::Basename;
    use Cwd 'abs_path';
    my ( undef, $mod_path, undef ) = fileparse( abs_path(__FILE__) );
    unshift @INC, $mod_path."lib";
}

# Dependencies
#--------------------
use Getopt::Std;

use BWA;
use GATK;
use LoadConfig;
use Picard;
use SampleSheet;
use SequenceDictionaryParser;
use SubmitToCluster;
use Trimmomatic;
#--------------------


# SUB
#--------------------

my @steps;
push(@steps, {'name' => 'trim'});
push(@steps, {'name' => 'align'});

&main();

sub printUsage {
  print "\nUsage: perl ".$0." project.csv first_step last_step\n";
  print "\t-c  config file\n";
  print "\t-s  start step, inclusive\n";
  print "\t-e  end step, inclusive\n";
  print "\t-n  nanuq sample sheet\n";
  print "\n";
  print "Steps:\n";
  for(my $idx=0; $idx < @steps; $idx++) {
    print "".($idx+1).'- '.$steps[$idx]->{'name'}."\n";
  }
  print "\n";
}

sub main {
  my %opts;
  getopts('c:s:e:n:', \%opts);
  
  if (!defined($opts{'c'}) || !defined($opts{'s'}) || !defined($opts{'e'}) || !defined($opts{'n'})) {
    printUsage();
    exit(1);
  }

  my %cfg = LoadConfig->readConfigFile($opts{'c'});
  my $rHoAoH_sampleInfo = SampleSheet::parseSampleSheetAsHash($opts{'n'});
  my $rH_seqDictionary = SequenceDictionaryParser::readDictFile(\%cfg);

  my $latestBam;
  for my $sampleName (keys %{$rHoAoH_sampleInfo}) {
    my $rAoH_sampleLanes = $rHoAoH_sampleInfo->{$sampleName};

    SubmitToCluster::initSubmit(\%cfg, $sampleName);
    for(my $current = $opts{'s'}-1; $current <= ($opts{'e'}-1); $current++) {
       my $fname = $steps[$current]->{'name'};
       my $subref = \&$fname;
       for my $rH_laneInfo (@$rAoH_sampleLanes) {
         # Tests for the first step in the list. Used for dependencies.
         &$subref($current != ($opts{'s'}-1), \%cfg, $sampleName, $rH_laneInfo, $rH_seqDictionary);
       } 
    }
  }  
}

sub trim {
  my $depends = shift;
  my $rH_cfg = shift;
  my $sampleName = shift;
  my $rH_laneInfo  = shift;
  my $rH_seqDictionary = shift;

    my $rH_trimDetails = Trimmomatic::trim($rH_cfg, $sampleName, $rH_laneInfo);
    my $trimJobIdVarName=undef;
    if(length($rH_trimDetails->{'command'}) > 0) {
      $trimJobIdVarName = SubmitToCluster::printSubmitCmd($rH_cfg, "trim", $rH_laneInfo->{'runId'} . "_" . $rH_laneInfo->{'lane'}, 'TRIM', undef, $sampleName, $rH_trimDetails->{'command'});
    }
  return $trimJobIdVarName;
}

sub align {
  my $depends = shift;
  my $rH_cfg = shift;
  my $sampleName = shift;
  my $rH_laneInfo  = shift;
  my $rH_seqDictionary = shift;

  my $jobDep = "";
  if($rH_laneInfo->{'runType'} eq "PAIRED_END") {
    my $rA_commands = BWA::aln($rH_cfg, $sampleName, $rH_laneInfo, $rH_trimDetails->{'pair1'}, $rH_trimDetails->{'pair2'}, $rH_trimDetails->{'single1'}, $rH_trimDetails->{'single2'}, '.paired.');

    my $read1JobId = SubmitToCluster::printSubmitCmd($rH_cfg, "aln", 'read1.'.$rH_laneInfo->{'runId'} . "_" . $rH_laneInfo->{'lane'}, 'READ1ALN', $trimJobIdVarName, $sampleName, $rA_commands->[0]);
    $read1JobId = '$'.$read1JobId;
    my $read2JobId = SubmitToCluster::printSubmitCmd($rH_cfg, "aln", 'read2.'.$rH_laneInfo->{'runId'} . "_" . $rH_laneInfo->{'lane'}, 'READ2ALN', $trimJobIdVarName, $sampleName, $rA_commands->[1]);
    $read2JobId = '$'.$read2JobId;
    my $bwaJobId = SubmitToCluster::printSubmitCmd($rH_cfg, "aln", 'sampe.'.$rH_laneInfo->{'runId'} . "_" . $rH_laneInfo->{'lane'}, 'BWA', $read1JobId.LoadConfig::getParam($rH_cfg, 'aln', 'clusterDependencySep').$read2JobId, $sampleName, $rA_commands->[2]);
    $bwaJobId = '$'.$bwaJobId;
    print 'BWA_JOB_IDS=${BWA_JOB_IDS}'.LoadConfig::getParam($rH_cfg, 'aln', 'clusterDependencySep').$bwaJobId."\n";
    
    # fake it and take the single1 end
    $rH_laneInfo->{'runType'} = 'SINGLE_END';
    my $rA_commands = BWA::aln($rH_cfg, $sampleName, $rH_laneInfo, $rH_trimDetails->{'pair1'}, $rH_trimDetails->{'pair2'}, $rH_trimDetails->{'single1'}, $rH_trimDetails->{'single2'}, '.single.');
    my $readJobId = SubmitToCluster::printSubmitCmd($rH_cfg, "aln", $rH_laneInfo->{'runId'} . "_" . $rH_laneInfo->{'lane'}, 'READALN', $trimJobIdVarName, $sampleName, $rA_commands->[0]);
    $readJobId = '$'.$readJobId;
    my $bwaJobId = SubmitToCluster::printSubmitCmd($rH_cfg, "aln", 'samse.'.$rH_laneInfo->{'runId'} . "_" . $rH_laneInfo->{'lane'}, 'BWA',  $readJobId, $sampleName, $rA_commands->[1]);
    $bwaJobId = '$'.$bwaJobId;
    print 'BWA_JOB_IDS=${BWA_JOB_IDS}'.LoadConfig::getParam($rH_cfg, 'default', 'clusterDependencySep').$bwaJobId."\n";

    my $laneDirectory = $sampleName . "/run" . $rH_laneInfo->{'runId'} . "_" . $rH_laneInfo->{'lane'} . "/";
    my $outputPairedBAM = $laneDirectory . $sampleName.'.paired.sorted.bam';
    my $outputSingleBAM = $laneDirectory . $sampleName.'.single.sorted.bam';
    my $outputBAM = $laneDirectory . $sampleName.'.sorted.bam';
    my @inputBams = ($outputPairedBAM, $outputSingleBAM);
    my $command = Picard::mergeFiles($rH_cfg, $sampleName, \@inputBams, $outputBAM);
    my $mergeJobId = undef;
    if(defined($command) && length($command) > 0) {
      $mergeJobId = SubmitToCluster::printSubmitCmd($rH_cfg, "mergePairs", undef, 'MERGEPAIRS', '$BWA_JOB_IDS', $sampleName, $command);
    }
    $jobDep = $mergeJobId;
  }
  else {
    my $rA_commands = BWA::aln($rH_cfg, $sampleName, $rH_laneInfo, $rH_trimDetails->{'pair1'}, $rH_trimDetails->{'pair2'}, $rH_trimDetails->{'single1'}, $rH_trimDetails->{'single2'});
    my $readJobId = SubmitToCluster::printSubmitCmd($rH_cfg, "aln", $rH_laneInfo->{'runId'} . "_" . $rH_laneInfo->{'lane'}, 'READALN', $trimJobIdVarName, $sampleName, $rA_commands->[0]);
    $readJobId = '$'.$readJobId;
    my $bwaJobId = SubmitToCluster::printSubmitCmd($rH_cfg, "aln", 'samse.'.$rH_laneInfo->{'runId'} . "_" . $rH_laneInfo->{'lane'}, 'BWA',  $readJobId, $sampleName, $rA_commands->[1]);
    $bwaJobId = '$'.$bwaJobId;
    print 'BWA_JOB_IDS=${BWA_JOB_IDS}'.LoadConfig::getParam($rH_cfg, 'default', 'clusterDependencySep').$bwaJobId."\n";
    $jobDep = '$BWA_JOB_IDS';
  }

  return $jobDep;
}

sub mergeLanes {
  my $depends = shift;
  my $rH_cfg = shift;
  my $sampleName = shift;
  my $rAoH_sampleLanes  = shift;
  my $rH_seqDictionary = shift;

  my $jobDependency = undef;
  if($depends > 0) {
    $jobDependency = '$BWA_JOB_IDS';
  }

  my $command = Picard::merge($rH_cfg, $sampleName, $rAoH_sampleLanes);
  my $mergeJobId = undef;
  if(defined($command) && length($command) > 0) {
    $mergeJobId = SubmitToCluster::printSubmitCmd($rH_cfg, "merge", undef, 'MERGELANES', $jobDependency, $sampleName, $command);
  }
  return $mergeJobId;
}

1;
