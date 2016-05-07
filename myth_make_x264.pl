#!/usr/bin/perl

######################################################################################################
######################################################################################################
###                                                                                                ###
### User Job for MythTV                                                                            ###
### Take recording and encode to smaller size													   ###
###														                                           ###
### This script will at some point flag commercials and generate a cut list, but that is           ###
### unstable at this time. For now, just re-encode with HandBrakeCLI                               ###
###                                                                                                ###
### Start this script with these parameters                                                        ###
###                                                                                                ###
### ../myth_make_x264.pl --chanid=%CHANID% --starttime=%STARTTIME% --directory=%DIR% --file=%FILE% ###
###                                                                                                ###
######################################################################################################
######################################################################################################

use utf8;
use strict;
use warnings;

use DBI;
use File::Spec;
use Getopt::Long;
use File::Basename;
use Date::Calc qw(Add_Delta_DHMS Day_of_Week);
use Data::Dumper;

our (@startArguments, $chanId, $startTime, $fileDir, $fileName, $quality, $verbose, $noCrop, $threads, $encoding);

@startArguments = @ARGV;

## Startparams
GetOptions( "chanid=i"      => \$chanId,
            "starttime=s"   => \$startTime,
            "directory=s"   => \$fileDir,
            "file=s"        => \$fileName,
            "quality:i"     => \$quality,
            "verbose"       => \$verbose,
            "noCrop"        => \$noCrop,
            "threads:s"     => \$threads,
            "encoding:s"    => \$encoding
        );

####################################################################################################
##############################################  Config  ############################################
####################################################################################################

## mythtv database connection
use constant MYTHHOST       => "localhost";
use constant MYTHDB         => "mythconverg";
use constant MYTHUSER       => "mythtv";
use constant MYTHPASS       => "mythtv";

## owner of file after successful run
## works only if mythtv user has sufficient permissions to do this
## set a valid value /bin/chown would accept, eg. "reznor:users"
## setting ownership after encoding will be skipped if this variable is empty
my $fileOwner       = "1000:1002";

## directory to store temp files in
## if it does not exist it will be created
my $tempDir         = "/media/mythtv/handbrake";

## target directory to store encoded files in
my $targetDir       = "/media/storage/completed/mythtv_recordings";

## Video

## Video constant quality encoding option
## Check handbrake manual for valid values
my $videoQualityDefault = 20;

# have to add 1 second to keyframe times
# for HD-PVR recordings, because ffmpeg
# makes up PTS values in that context,
# and they start at 1 second, rather
# than at zero!  To be safe, we insert
# two keyframes, one for PTS offset 0,
# and another for offset 1.
my $pts_time_offset = 1.00;

## Audio

## preferred audio language
## comma separated list
## check the list at
## http://www.loc.gov/standards/iso639-2/php/code_list.php
## for the correct iso639-1 codes
my $prefLang        = 'en';

## audio languages you wish to skip
## comma separated list
## mis = miscellaneous language
my $skipLang        = 'mul,mis,fr';

## The following filetypes are mapped to integer values
##
## 1 => ac3
## 2 => mp2
## 3 => any other filetypes

## Preferred way of handbrake treating audio tracks by codec.
## Here the usual used codecs for dvb are listed as keys
## and the values represent the corresponding way how
## handbrake shall treat them.
## Since I don't know what I would choose if I had HD-tuners,
## I don't assume any values ... this is up to you :)
our $audioCodecMap = {  1 => 'copy', # ac3 streams will be copied as they are
                        2 => 'lame', # mp2 streams will be converted to mp3
                        3 => 'lame'  # unknown filetypes are going to be converted to mp3
                     };

## Encoding priority
my $niceValue       = 15;

## Maximum allowed parallel executions of this script
my $maxExec         = 2;

## If $maxExec would exceed the allowed value, the amount of seconds to wait
## for other encoding processes to finish which were startet by this script
my $sleepInterval   = 200;

## Maximum allowed time to sleep in seconds before aborting when waiting for other
## encodings started by this script
## If set to 0, it will wait forever
my $maxSleepTime    = 0;

## If set to 1, daylight savings time is considered
my $DST = 1;

####################################################################################################
##############################################  Start  #############################################
####################################################################################################

## Check DB connection
getDBConnection();

## Verify Starttime
my ($fileChanId, $fileStartTime) = split /_/, $fileName;

## Replace file extension
$fileStartTime =~ s/\....//;

$startTime = $fileStartTime if ($startTime != $fileStartTime);

## if recording filename start time is different from starttime of command line parameters' start time
## we have a recording pre 0.26 and time is in UTC .. so we choose to use file starttime
my $startYear    = $startTime;
$startYear       =~ s/^(....).*/$1/;

my $startMonth   = $startTime;
$startMonth      =~ s/^....(..).*/$1/;

my $startDay     = $startTime;
$startDay        =~ s/^......(..).*/$1/;

my $startHours   = $startTime;
$startHours      =~ s/^........(..).*/$1/;

my $startMinutes = $startTime;
$startMinutes    =~ s/^..........(..).*/$1/;

my $startSeconds = $startTime;
$startSeconds    =~ s/^............(..)$/$1/;

my $startWeekday = Day_of_Week($startYear, $startMonth, $startDay);

my $timeShift   = (checkDaylightSavingsTime($startDay, $startMonth, $startWeekday)) ? 1 : -1;
$timeShift      = ($DST == 1) ? $timeShift : 0;

my ($year, $month, $day, $hh, $mm, $ss) = Add_Delta_DHMS(
    $startYear, $startMonth,    $startDay,  $startHours,    $startMinutes,  $startSeconds,
                                0,          $timeShift,             0,              0);

our $utcStartTime = sprintf ( "%04d%02d%02d%02d%02d%02d", $year, $month, $day, $hh, $mm, $ss );

## Logfile
our $logFile = $tempDir . "/" . $chanId . "_" . $startTime . ".log";

## Cut list file
our $cutListFile = $tempDir . "/" . $chanId . "_" . $startTime . "/" . $chanId . "_" . $startTime . ".cut";

## If called interactively, log to STDOUT and logfile
our $hasTty = -t STDIN && -t STDOUT;

## Switch off output buffering
$| = 1;

## Open logfile
open (LOG, ">> $logFile");

my $ncr = '';
my $ver = '';
my $thr;

if (!$threads || $threads eq '')
{
    $threads = 'auto';
}
else
{
    $thr = '--threads=' . $thr;
}

if(!$encoding || $encoding eq '')
{
    $encoding = "x264";
}

$ncr = '--noCrop' if ($noCrop);
$ver = '--verbose' if ($verbose);

## Echo start of script
toLog("Start encoding $fileName", "INFO");
toLog("Script started with " . join(' ', @startArguments), "INFO");;

## What is my name?
my $scriptName = basename($0);

## Check command line options
checkOptions($chanId, $startTime, $fileDir, $fileName, $quality, $verbose, $scriptName, $videoQualityDefault);

## Directory where all the work is donw
my $workDir = $tempDir . "/" . $chanId . "_" . $startTime;

## Return code
my $rc = 0;

## Output of command line tools
my $output;

## Required programs for this script
my $requiredPrograms = {    "mythtranscode"     => "media-video/mythtv",
                            "mythutil"          => "media-video/mythtv",
                            "mythcommflag"      => "media-video/mythtv",
                            "HandBrakeCLI"      => "media-video/handbrake",
                            "mkvmerge"          => "media-video/mkvtoolnix",
                            "mediainfo"         => "media-video/mediainfo",
                            "avconv"            => "media-video/avcodec",
                            "ffmpeg"            => "media-video/ffmpeg"
                        };

## If projectx is going to be used ... add requirements
$requiredPrograms->{'projectx'} = 'media-video/projectx';
$requiredPrograms->{'mplex'} = 'media-video/mjpegtools';

## Check for required programs and replace package names by absolute path to program
toLog("Checking requirements", "INFO");
requirements($requiredPrograms);

## Check if maximum value of simultaneous encodings will exceed
toLog("Check if other instances are running", "INFO");
checkRunning($scriptName, $workDir, $maxExec, $sleepInterval, $maxSleepTime);

## Create working directory
toLog("Creating working directory '" . $workDir . "'", "INFO");
if (! -d $workDir)
{
    system("mkdir -p $workDir");
    abnormalExit("Could not create " . $workDir . " : " . $!) if ($? != 0);
}

## Gather information about recording's title, subtitle, season and episode data
toLog("Gather information about recording's title, subtitle, season and episode", "INFO");
my $recordingInfo = getRecordingInfo($fileDir, $fileName);

## Gather info about recording's tracks
toLog("Gather information about recording's tracks", "INFO");
my $mediaInfo = getMediaInfo($fileDir, $fileName);

my $cutData;

toLog("MediaInfo Codec: '" . $mediaInfo->{'Codec'}  . "'", "INFO");

##First things first, lets flag commercials
#toLog("Flagging Commercials (Generating CutList)","INFO");
#flagCommercials($chanId, $startTime);

#if ( $mediaInfo->{'Codec'} eq 'AVC' )
#{
    ## Get avconv cutlist information
    #$cutData = getCutList($chanId, $startTime, $mediaInfo, $pts_time_offset);
#}

## Start processing
my $cmd;

#if ( $mediaInfo->{'Codec'} ne 'AVC' )
#{
    ## Generate cutlist from mythtv cutpoints for projectx
#    toLog("Generating cutlist for projectx", "INFO");

#    if (! writeCutList($chanId, $startTime) )
#    {
#        abnormalExit("Generating cutlist failed.");
#    }

    # Write X.ini file for projectx to select teletext subtitles
    # Commented out due to the fact that it's quite impossible to choose the right teletext page
    # since pages are different across channels
    # toLog("Writing X.ini file for projectx", "INFO");

    # if (! writeXini() )
    # {
    #   abnormalExit("Writing X.ini file failed.");
    # }
    #my $cmd = 'nice -n ' . $niceValue . ' ' . $$requiredPrograms{'projectx_cli'} . ' -ini ' . $projectxIniFile . ' -id ' . $mediaInfo->{'video'} . ',104,' . $audioIds

#    my $audioIds = join (',', keys %{$mediaInfo->{'audio'}});

    ## Start projectx which will cut out the commercials
#    toLog("Starting projectx", "INFO");
#    $cmd = 'nice -n ' . $niceValue . ' ' . $$requiredPrograms{'projectx_cli'} . ' -id ' . $mediaInfo->{'video'} . ',' . $audioIds
#            . ' -out ' . $workDir . ' -cut ' . $cutListFile . ' -demux ' . $fileDir . '/' . $fileName . ' 2>&1';
#    toLog("Executing: $cmd", "INFO") if ($verbose);

#    $output = `$cmd`;
#    toLog($output) if ($verbose);
#    abnormalExit("projectx exited with errors, run " . $scriptName . " --verbose and check logfile " . $logFile . " for errors.") if ($? != 0);

#    toLog("projectx finished", "INFO");
#}

## Get audio channel numbers, codecs and bitrates
my (@channelLanguages, @channelNumbers, @channelCodecs, @channelBitrates, @channelFilenames, $videoFilename, @channelTrackPos, @channelAvconvTrackPos);
my $channelCounter = 0;

toLog(Dumper($mediaInfo->{'audio'}), "VERB") if ($verbose);

foreach (sort {$mediaInfo->{'audio'}{$a}->{'streamPriority'} <=> $mediaInfo->{'audio'}{$b}->{'streamPriority'}} keys %{$mediaInfo->{'audio'}})
{
    # print $mediaInfo->{'audio'}{$_}{'streamPriority'} . "\n";
    push(@channelLanguages, $mediaInfo->{'audio'}{$_}->{'language'});
    push(@channelNumbers, $mediaInfo->{'audio'}{$_}->{'channels'});
    push(@channelCodecs, $mediaInfo->{'audio'}{$_}->{'streamType'});
    push(@channelBitrates, $mediaInfo->{'audio'}{$_}->{'bitrate'});
    push(@channelAvconvTrackPos, '-codec:a:0:' . $mediaInfo->{'audio'}{$_}->{'trackPos'} . ' copy');
    push(@channelTrackPos, $mediaInfo->{'audio'}{$_}->{'trackPos'});

    if ($channelCounter > 0 && $mediaInfo->{'Codec'} ne 'AVC')
    {
        if (-e $workDir . '/' . sprintf("%s-%02d", $chanId . '_' . $startTime, $channelCounter) . '.' . $mediaInfo->{'audio'}{$_}->{'streamType'})
        {
            push(@channelFilenames, $workDir . '/' . sprintf("%s-%02d", $chanId . '_' . $startTime, $channelCounter) . '.' . $mediaInfo->{'audio'}{$_}->{'streamType'});
        }
        elsif (-e $workDir . '/' . sprintf("%s-%02d", $chanId . '_' . $utcStartTime, $channelCounter) . '.' . $mediaInfo->{'audio'}{$_}->{'streamType'})
        {
            push(@channelFilenames, $workDir . '/' . sprintf("%s-%02d", $chanId . '_' . $utcStartTime, $channelCounter) . '.' . $mediaInfo->{'audio'}{$_}->{'streamType'});
        }
    }
    else
    {
        if (-e $workDir . '/' . $chanId . '_' . $startTime . '.' . $mediaInfo->{'audio'}{$_}->{'streamType'})
        {
            push(@channelFilenames, $workDir . '/' . $chanId . '_' . $startTime . '.' . $mediaInfo->{'audio'}{$_}->{'streamType'});
        }
        elsif (-e $workDir . '/' . $chanId . '_' . $utcStartTime . '.' . $mediaInfo->{'audio'}{$_}->{'streamType'})
        {
            push(@channelFilenames, $workDir . '/' . $chanId . '_' . $utcStartTime . '.' . $mediaInfo->{'audio'}{$_}->{'streamType'});
        }
    }
}

my $audioLanguages      = join (',', @channelLanguages);
my $audioNumbers        = join (',', @channelNumbers);
my $audioCodecs         = join (',', @channelCodecs);
my $audioBitrates       = join (',', @channelBitrates);
my $audioFilenames      = join (' ', @channelFilenames);
my $avconvAudioTracks   = join (' ', @channelAvconvTrackPos);
my $audioTracks         = join (',', 1 .. ($#channelAvconvTrackPos + 1));

toLog("audio tracks: " . $avconvAudioTracks . "\n", "VERB") if ($verbose);
toLog("audio bitrates: " . $audioBitrates . "\n", "VERB") if ($verbose);

#if ( $mediaInfo->{'Codec'} ne 'AVC' )
#{
#    if (-e $workDir . '/' . $chanId . '_' . $startTime . '.m2v')
#    {
#        $videoFilename  = $workDir . '/' . $chanId . '_' . $startTime;
#    }
#    elsif (-e $workDir . '/' . $chanId . '_' . $utcStartTime . '.m2v')
#    {
#        $videoFilename  = $workDir . '/' . $chanId . '_' . $utcStartTime;
#    }
#    else
#    {
#        abnormalExit("Could not identify video track of the recording after demultiplexing.\nNeither \n" . $workDir . "/" . $chanId . "_" . $startTime . ".m2v\nnor\n" . $workDir . "/" . $chanId . "_" . $utcStartTime . ".m2v did match...");
#    }
#
#    ## Start mplex to multiplex streams after cutting
#    toLog("Starting mplex", "INFO");
#    $cmd = 'nice -n ' . $niceValue  . ' ' . $$requiredPrograms{'mplex'} . ' --format 3 --vbr -o ' . $workDir . '/' . $fileName . '.0.ts'
#            . ' ' . $videoFilename . '.m2v ' . $audioFilenames . ' 2>&1';
#    toLog("Executing: $cmd", "INFO") if ($verbose);
#
#    $output = `$cmd`;
#    toLog($output) if ($verbose);
#    abnormalExit("mplex exited with errors, run " . $scriptName . " --verbose and check logfile " . $logFile . " for errors.") if ($? != 0);
#
#    toLog("mplex finished", "INFO");
#}
#
#my @parts;
#my $part = 0;
#
#if ( $mediaInfo->{'Codec'} eq 'AVC' )
#{
#    ## Now that we have all information we need, let's get to honor the cut list ... and write parts with avconv
#    toLog("Starting ffmpeg cutting out video/audio honoring the cut list", "INFO");
#
#    if (scalar $$cutData{'cutLists'} != 0)
#    {
#        foreach ($$cutData{'cutLists'})
#        {
#            foreach my $cutList (@{$_})
#            {
#                my $start       = $$cutList{'start'};
#                my $duration    = $$cutList{'duration'};
#                my $keyFrames   = $$cutData{'keyFrames'};
#
#                $cmd = 'nice -n ' . $niceValue . ' ' . $$requiredPrograms{'ffmpeg'}
#                        . ' -i ' . $fileDir . '/' . $fileName
#                        . ' -force_key_frames ' . $keyFrames
#                        . ' -ss ' . $start
#                        . ' -codec copy'
#                        . ' -t ' . $duration
#                        . ' -y'
#                        . ' -codec:v:0:1 copy -sn ' . $avconvAudioTracks . ' -f mpegts'
#                        . ' ' . $workDir . '/' . $fileName . '.' . $part . '.ts 2>&1';
#                toLog("Executing: $cmd", "VERB") if ($verbose);
#
#                $output = `$cmd`;
#                toLog($output, 'VERB') if ($verbose);
#                abnormalExit("ffmpeg exited with errors, run " . $scriptName . " --verbose and check logfile " . $logFile . " for errors.") if ($? != 0);
#                push(@parts, $workDir . '/' . $fileName . '.' . $part . '.ts');
#                $part++;
#            }
#        }
#
#    } else {
#
#        $cmd = 'nice -n ' . $niceValue . ' ' . $$requiredPrograms{'ffmpeg'}
#                . ' -i ' . $fileDir . '/' . $fileName
#                . ' -codec copy'
#                . ' -codec:v:0:1 copy'
#                . ' -sn '
#                . ' -b:a ' . ($audioBitrates * 1000)
#                . $avconvAudioTracks
#                . ' -f mpegts'
#                . ' -y'
#                . ' ' . $workDir . '/' . $fileName . '.' . $part . '.ts 2>&1';
#        toLog("Executing: $cmd", "VERB") if ($verbose);
#
#        $output = `$cmd`;
#        toLog($output, 'VERB') if ($verbose);
#        abnormalExit("ffmpeg exited with errors, run " . $scriptName . " --verbose and check logfile " . $logFile . " for errors.") if ($? != 0);
#        push(@parts, $workDir . '/' . $fileName . '.' . $part . '.ts');
#        $part++;
#    }
#}
#
#if ($#parts > 0)
#{
#    if ( $mediaInfo->{'Codec'} eq 'AVC' )
#    {
#        toLog("Concatenating all AVC parts", "INFO");
#
#        $cmd = 'nice -n ' . $niceValue . ' ' . $$requiredPrograms{'ffmpeg'} . ' -i "concat:' . join ('|', @parts) . '" -c copy ' . $workDir . '/' . $fileName . '.ts 2>&1';
#        toLog("Executing: $cmd", "VERB") if ($verbose);
#
#        $output = `$cmd`;
#        toLog($output, 'VERB') if ($verbose);
#        abnormalExit("AVC concatenation exited with errors, run " . $scriptName . " --verbose and check logfile " . $logFile . " for errors.") if ($? != 0);
#
#    }## else {
#
###       toLog("Concatenating all MPG parts", "INFO");
###
###       $cmd = 'cat ' . join (' ', @parts) . ' > ' . $workDir . '/' . $fileName . '.ts 2>&1';
###       toLog("Executing: $cmd", "VERB") if ($verbose);
###
###      $output = `$cmd`;
###       toLog($output, 'VERB') if ($verbose);
###       abnormalExit("MPG concatenation exited with errors, run " . $scriptName . " --verbose and check logfile " . $logFile . " for errors.") if ($? != 0);
###   }
#}
#else
#{
#    $cmd = 'mv ' . $workDir . '/' . $fileName . '.0.ts ' . $workDir . '/' . $fileName . '.ts 2>&1';
#    toLog("Executing: $cmd", "VERB") if ($verbose);
#
#    $output = `$cmd`;
#    toLog($output, 'VERB') if ($verbose);
#    abnormalExit("renaming part 0 file exited with errors, run " . $scriptName . " --verbose and check logfile " . $logFile . " for errors.") if ($? != 0);
#}

my $videoQuality = ($quality) ? $quality : $videoQualityDefault;

## Now that we have all information we need, let's get to encode it with handbrake
toLog("Starting handbrake", "INFO");
$cmd = 'nice -n ' . $niceValue . ' ' . $$requiredPrograms{'HandBrakeCLI'} . ' -i ' . $fileDir . '/' . $fileName
        . ' -o ' . $workDir . '/' . $fileName . '.handbrake.mkv -a ' . $audioTracks . ' -E ' . $audioCodecs . ' -B ' . $audioBitrates
        . ' -A ' . $audioLanguages . ' -f mkv -e ' . $encoding . ' -q ' . $videoQuality
        . ' -x ref=2:bframes=2:subme=6:mixed-refs=0:weightb=0:8x8dct=0:trellis=0:threads=' . $threads . ' -2'
        . ' -5 -7';
$cmd    .= ' -T' if($encoding eq "x264");
$cmd    .= ' --crop 0:0:0:0' if ($noCrop);
$cmd    .= ' -s scan -F -N ' . $prefLang . ' --native-dub 2>&1';
toLog("Executing: $cmd", "VERB") if ($verbose);

$output = `$cmd`;
toLog($output, 'VERB') if ($verbose);
abnormalExit("handbrake exited with errors, run " . $scriptName . " --verbose and check logfile " . $logFile . " for errors.") if ($? != 0);

toLog("handbrake finished", "INFO");

## Create a clean filename
my $title = $$recordingInfo{'title'};
$title =~ s#[<>\*\?\|:\"\\/]##g;

my $subtitle = $$recordingInfo{'subtitle'};
$subtitle =~ s#[<>\*\?\|:\"\\/]##g;
my $metaSubtitle = $subtitle;
$subtitle = ($title =~ m/^$metaSubtitle$/ || $subtitle eq '') ? '' : '.' . $subtitle;

my $episode;
$episode = ($$recordingInfo{'season'} != 0 && $$recordingInfo{'season'} ne ''
            && $$recordingInfo{'episode'} != 0 && $$recordingInfo{'episode'} ne '') ?
            sprintf(".S%02dE%02d", $$recordingInfo{'season'}, $$recordingInfo{'episode'}) : '';

my $encodingText;
$encodingText = '.' . $encoding;

my $videoResolution;
$videoResolution = '.' . $mediaInfo->{'vheight'} .'p';

my $completeTitle   = $title . $episode . $encodingText . $videoResolution;
my $metaTitle       = ($subtitle ne '') ? $metaSubtitle : $title;

## Create audio language names by muxed audio tracks
## Audio TrackId will start at 2 (1 is video track)
my $mkvmergeAudio;
my $mkvmergeAudioTrackId = 1;
foreach (@channelLanguages)
{
    $mkvmergeAudio .= " --language " . $mkvmergeAudioTrackId . ":" . $_;
    $mkvmergeAudioTrackId++;
}

## Check if target file already exists
## If so, append a timestamp to the target filename
if (-e $targetDir . "/" . $completeTitle . ".mkv")
{
    (my $sec, my $min, my $hour, my $day, my $month, my $year) = (localtime)[0,1,2,3,4,5];
    my $timeStamp = sprintf("%04d%02d%02d%02d%02d%02d", $year+1900, $month+1, $day, $hour, $min, $sec);
    $completeTitle = $completeTitle . "_" . $timeStamp;
}

## Put all information we gathered into the .mkv file/name
## And let mkvmerge write the finished file to the target directory
toLog("Starting mkvmerge", "INFO");

$cmd = 'nice -n ' . $niceValue . ' ' . $$requiredPrograms{'mkvmerge'} . ' -o ' . $targetDir . '/' . '"' . $completeTitle . '.mkv"'
        . ' --title "' . $metaTitle . '" ' . $mkvmergeAudio . ' --default-track 1:yes'
        . ' ' . $workDir . '/' . $fileName . '.handbrake.mkv 2>&1';
toLog("Executing: $cmd", "VERB") if ($verbose);

$output = `$cmd`;
toLog($output, 'VERB') if ($verbose);
abnormalExit("mkvmerge exited with errors, run " . $scriptName . " --verbose and check logfile " . $logFile . " for errors.") if ($? != 0);

toLog("mkvmerge finished", "INFO");

toLog("Cleaning up temporary files", "INFO");
cleanup($workDir, $fileOwner, $targetDir . "/" . $completeTitle . ".mkv");

toLog("Finished encoding to file '$completeTitle.mkv' ($fileName)", "INFO");
close(LOG);

exit 0;

####################################################################################################
##############################################  Functions ##########################################
####################################################################################################

sub toLog
{
    my ($message, $type) = @_;

    $type = 'INFO' if ( ! $type );

    my ($sec, $min, $hour, $day, $month, $year) = (localtime)[0,1,2,3,4,5];

    my $timeStamp = sprintf("%04d-%02d-%02d %02d:%02d:%02d", $year+1900, $month+1, $day, $hour, $min, $sec);

    my $formattedMessage = sprintf("%s %-5s %s\n", $timeStamp, $type, $message);

    print $formattedMessage if ($hasTty);

    print LOG $formattedMessage;
}

sub abnormalExit
{
    my $message = $_[0];

    toLog($message, 'FATAL');
    closeDBConnection();
    close(LOG);

    exit 1;
}

sub requirements
{
    my $requiredPrograms = $_[0];
    my $wrc = 0;

    foreach my $program (keys %$requiredPrograms)
    {
        my $absolutePath = `which $program`;
        chomp($absolutePath);

        if ($? != 0)
        {
            toLog("Required program " . $program . " (" . $$requiredPrograms{$program} . ") not found.", "FATAL");
            $wrc = 1;
        } else {
            @$requiredPrograms{$program} = $absolutePath;
        }
    }
}

sub checkRunning
{
    my ($scriptName, $workDir, $maxExec, $sleepInterval, $maxSleepTime) = @_;
    my @pids = ();
    my $slept = 0;

    my $curProcs = `ps aux | grep $scriptName | grep -v grep | wc -l`;
    chomp($curProcs);

    ## Check if encoding of this recording has already been started.
    ## If so, abort.
    if (-d $workDir)
    {
        abnormalExit("Encoding of this recording already running in directory " . $workDir . ". Or an error occurred in previous attempt to encode this recording. Aborting.");
    }

    while ($curProcs > $maxExec)
    {
        $curProcs = `ps aux | grep $scriptName | grep -v grep | wc -l`;
        chomp($curProcs);

        toLog($scriptName . " maximum amount of simultaneous executions reached. Waiting " . $sleepInterval . " seconds before trying again.", "INFO");
        sleep($sleepInterval);
        $slept += $sleepInterval;

        if ($maxSleepTime > 0 && $slept > $maxSleepTime)
        {
            toLog("Maximum waiting time of " . $maxSleepTime . " seconds exceeded.", "FATAL");
            abnormalExit("Something might be wrong, please check unfinished encoding jobs. Aborting.");
        }
    }
}

sub in_array
{
    my ($item, $array) = @_;
    my %hash = map { $_ => 1 } @$array;
    if ($hash{$item}) { return 1; } else { return 0; }
}

sub getDBConnection
{
    our $dbh;

    if (!$dbh)
    {
        ## Establish DB connection
        $dbh = DBI->connect("DBI:mysql:" . MYTHDB . ":" . MYTHHOST, MYTHUSER, MYTHPASS);

        if (!$dbh)
        {
            abnormalExit("Can't connect to database.");
        }
    }

    return $dbh;
}

sub execSQL
{
    my $sql = $_[0];

    my @sqlResults;
    my %results;

    my $db = getDBConnection();

    my $sqlQuery  = $db->prepare($sql)
    or abnormalExit("Can't prepare $sql: $db->errstr\n");
    $sqlQuery->execute
    or abnormalExit("can't execute the query: $sqlQuery->errstr\n");

    my $rows        = $sqlQuery->rows;

    if ($rows == 0)
    {
        $sqlQuery->finish;
        $results{'rc'} = 0;

        return \%results;
    }

    for ( my $i = 0; $i < $rows; $i++)
    {
        $sqlResults[$i] = $sqlQuery->fetchrow_hashref;
    }

    $sqlQuery->finish;

    $results{'rc'} = 1;
    $results{'rs'} = \@sqlResults;

    return \%results;
}

sub closeDBConnection
{
    my $db = getDBConnection();
    $db->disconnect or abnormalExit("Can't disconnect from database.");
}

sub flagCommercials($chanId, $startTime)
{
    my ($chanId, $startTime) = @_;
    #######################
    ## Clear the cutlist
    #######################
    toLog("Clearing cutlist","INFO");
    $cmd = 'nice -n ' . $niceValue . ' ' . $$requiredPrograms{'mythutil'} . ' --clearcutlist --chanid=' . $chanId . ' --starttime="' . $startTime . '" 2>&1';
    toLog("Executing: $cmd", "VERB") if ($verbose);

    $output = `$cmd`;
    chomp($output);
    toLog($output, 'VERB') if ($verbose);
    abnormalExit("mythutil exited with errors, run " . $scriptName . " --verbose and check logfile " . $logFile . " for errors.") if ($? != 0);

    ##########################
    ## Rebuild the seek table
    ##########################
    toLog("Rebuild the seek table","INFO");
    $cmd = 'nice -n ' . $niceValue . ' ' . $$requiredPrograms{'mythcommflag'} . ' --rebuild --chanid=' . $chanId . ' --starttime="' . $startTime . '" 2>&1';
    toLog("Executing: $cmd", "VERB") if ($verbose);

    $output = `$cmd`;
    chomp($output);
    toLog($output, 'VERB') if ($verbose);
    abnormalExit("mythcommflag exited with errors while trying to rebuild the seek table, run " . $scriptName . " --verbose and check logfile " . $logFile . " for errors.") if ($? != 0);

    ####################
    ## Flag Commercials
    ####################
    toLog("Flagging Commercials","INFO");
    $cmd = 'nice -n ' . $niceValue . ' ' . $$requiredPrograms{'mythcommflag'} . ' --chanid=' . $chanId . ' --starttime="' . $startTime . '" 2>&1';
    toLog("Executing: $cmd", "VERB") if ($verbose);

    $output = `$cmd`;
    chomp($output);
    toLog($output, 'VERB') if ($verbose);
    abnormalExit("mythcommflag exited with errors, run " . $scriptName . " --verbose and check logfile " . $logFile . " for errors.") if ($? != 0);

    ########################
    ## Generate new cutlist
    ########################
    toLog("Generating new cutlist","INFO");
    $cmd = 'nice -n ' . $niceValue . ' ' . $$requiredPrograms{'mythutil'} . ' --gencutlist --chanid=' . $chanId . ' --starttime="' . $startTime . '" 2>&1';
    toLog("Executing: $cmd", "VERB") if ($verbose);

    $output = `$cmd`;
    chomp($output);
    toLog($output, 'VERB') if ($verbose);
    abnormalExit("mythutil exited with errors, run " . $scriptName . " --verbose and check logfile " . $logFile . " for errors.") if ($? != 0);
}

sub getCutList
{
    my ($chanId, $startTime, $mediaInfo, $pts_time_offset) = @_;

    my $cutList;
    my $fkf;
    my $spl;
    my @returnKeyFrames;
    my @returnCutLists;
    my %returnCutList;
    my %returnData;

    ## fix spl and fkf concatenation error
    $spl = "";
    $fkf = "";

    ## Fetch cutlist information
    toLog("Starting mythutil to retrieve cut info", "INFO");

    ## Retrieve video track id
    $cmd = 'nice -n ' . $niceValue . ' ' . $$requiredPrograms{'mythutil'} . ' -q -q --getcutlist --chanid=' . $chanId . ' --starttime="' . $startTime . '" 2>&1';
    toLog("Executing: $cmd", "VERB") if ($verbose);

    $output = `$cmd`;
    chomp($output);
    toLog($output, 'VERB') if ($verbose);
    abnormalExit("mythutil exited with errors, run " . $scriptName . " --verbose and check logfile " . $logFile . " for errors.") if ($? != 0);

    if ( $output =~ m/^Cutlist: (.*)$/ )
    {
        $cutList = $1;
    }

    if ( $cutList )
    {
        my $inverse_cutlist;
        my $inv_prev = 0;
        my $decr = 0;

        my $ctr = 0;
        my @intervals = split(",", $cutList);

        foreach (@intervals)
        {
            my $start = (split("-", $_))[0];
            my $end = (split("-", $_))[1];

            if ( $ctr != 0 )
            {
                $fkf .= ",";
            }

            if ( $start > $inv_prev ) {
                $decr = $start - 1;
                $inverse_cutlist .= "$inv_prev-$decr,";
            }
            $inv_prev = $end + 1;


            my $start2 = $inv_prev / $$mediaInfo{'fps'};
            my $end2 = ( $decr + 1 ) / $$mediaInfo{'fps'};

            # Make sure the order of new keyframes is correct.  For
            # very short cuts, we have to reorder them because of the
            # pts_time_offset silliness.
            if ( $pts_time_offset != 0) {
                if ( $end2 - $start2 < $pts_time_offset ) {

                    $fkf .= sprintf("%.2f,%.2f,%.2f,%.2f", $start2 - 0.005, $end2 - 0.005, $start2 + $pts_time_offset - 0.005, $end2 + $pts_time_offset - 0.005 );

                } else {

                    $fkf .= sprintf("%.2f,%.2f,%.2f,%.2f", $start2 - 0.005, $start2 + $pts_time_offset - 0.005, $end2 - 0.005, $end2 + $pts_time_offset - 0.005 );

                }
            } else {
                $fkf .= sprintf("%.2f,%.2f", $start2 - 0.005, $end2 - 0.005);
            }

            $ctr++;
        }

        #$inverse_cutlist .= "$inv_prev-1300000";   # a nice 12-hour range

        my $ctr2 = 0;
        @intervals = split(",", $inverse_cutlist);
        foreach (@intervals) {
            my $start = (split("-", $_))[0];
            my $end = (split("-", $_))[1];

            if ( $ctr2 != 0 ) {
            $spl .= ",";
            }

            # Subtract 2 from start and from end+1, so that
            # floating-point roundoff doesn't make us fall through to
            # the next keyframe.  ffmpeg doesn't make consecutive
            # keyframes without explicit directions to do so, so this
            # should always work.
            my $start2 = ( $start - 2) / $$mediaInfo{'fps'};
            my $end2 = ( $end - 1 ) / $$mediaInfo{'fps'};

            if ( $start2 < 0.005 ) {
            $start2 = 0.005;
            }
            if ( $end2 < 0.005 ) {
            $end2 = 0.005;
            }

            $spl .= sprintf("%s-%s", $start2 - 0.005, $end2 - 0.005);

            $ctr2++;
        }
    }

    toLog("spl: " . $spl . "\n", 'VERB') if ($verbose);

    foreach (split(",", $spl))
    {
        my @intervals = split("-", $_);
        push(@returnCutLists, {'start' => $intervals[0] - 0.005, 'duration' => $intervals[1] - $intervals[0] - 0.005});
    }

    toLog(Dumper(@returnCutLists) . "\n", 'VERB') if ($verbose);

    toLog("fkf: " . $fkf . "\n", 'VERB') if ($verbose);

    #foreach (split("|", $fkf))
    #{
    #   push(@returnKeyFrames, $_);
    #}

    #toLog(Dumper(@returnCutLists) . "\n", 'VERB') if ($verbose);

    $returnData{'cutLists'} = \@returnCutLists;
    $returnData{'keyFrames'} = $fkf;
    #$returnData{'keyFrames'} = \@returnKeyFrames;

    return \%returnData;
}

sub writeCutList
{
    my ($chanId, $startTime) = @_;

    my $projectxCutList = "CollectionPanel.CutMode=0\n";
    my $sql;

    ## Establish DB connection
    my $db = getDBConnection();

    ## Fetch cut-in points
    # $sql          = "SELECT mark FROM recordedmarkup WHERE chanid='" . $chanId . "' AND starttime='" . $startTime . "' AND type=0 ORDER BY mark;";
    # my $cutInList = execSQL($sql);

    ## Fetch cut-out points
    $sql            = "SELECT mark FROM recordedmarkup WHERE chanid='" . $chanId . "' AND starttime='" . $startTime . "' AND type=1 ORDER BY mark;";
    toLog($sql, 'VERBOSE') if ($verbose);
    my $cutOutList  = execSQL($sql);

    ## Fetch all cut points
    $sql            = "SELECT mark FROM recordedmarkup WHERE chanid='" . $chanId . "' AND starttime='" . $startTime . "' AND type IN (0,1) ORDER BY mark;";
    toLog($sql, 'VERBOSE') if ($verbose);
    my $cutList     = execSQL($sql);

    if ( ! $$cutOutList{'rc'} || ! $$cutList{'rc'} ) # || ! $$cutOutList{'rs'}[0]{'mark'} || ! $$cutList{'rs'}[0]{'mark'} )
    {
        ## Try again with UTC time
        $startTime = $utcStartTime;

        ## Fetch cut-out points
        $sql            = "SELECT mark FROM recordedmarkup WHERE chanid='" . $chanId . "' AND starttime='" . $startTime . "' AND type=1 ORDER BY mark;";
        toLog($sql, 'VERBOSE') if ($verbose);
        $cutOutList = execSQL($sql);

        ## Fetch all cut points
        $sql            = "SELECT mark FROM recordedmarkup WHERE chanid='" . $chanId . "' AND starttime='" . $startTime . "' AND type IN (0,1) ORDER BY mark;";
        toLog($sql, 'VERBOSE') if ($verbose);
        $cutList        = execSQL($sql);

        ## If there's still no cut for this recording ... abort..
        if ( ! $$cutOutList{'rc'} || ! $$cutList{'rc'} )
        {
	    #mythutil --gencutlist --chanid $chanId --starttime $startTime
            abnormalExit("No cut / edit info for $fileDir/$fileName found!");
        }
    }

    # toLog("First Cut: '" . $$cutOutList{'rs'}[0]{'mark'} . "', First Edit: '" . $$cutList{'rs'}[0]{'mark'} . "'", "INFO");

    ## Check if 0 has to be added as initial cut point
    if ( $$cutOutList{'rs'}[0]{'mark'} == $$cutList{'rs'}[0]{'mark'} )
    {
        toLog("First Cut is a cut-out point. Inserting '0' to cutlist as first cut.", 'INFO');
        $projectxCutList .= "0\n";
    }

    foreach my $rs ($$cutList{'rs'})
    {
        foreach my $row (@$rs)
        {
            ## Find the key frame (mark type 9) right before each cut mark,
            ## extract the byte offset, write it into the ProjectX cutlist
            $sql            = "SELECT offset FROM recordedseek WHERE chanid='" . $chanId . "' AND starttime='" . $startTime .
                            "' AND type=9 AND mark >= " . $$row{'mark'} . " AND mark < " . ($$row{'mark'} + 100) . " ORDER BY offset LIMIT 1;";
            my $offset      = execSQL($sql);

            # print "mark: " . $$row{'mark'} . " offset: " . $$offset{'rs'}[0]{'offset'} . "\n";
            if ( ! $$offset{'rs'}[0]{'offset'} )
            {
                abnormalExit("Could not determine offset for mark " . $$row{'mark'});
            }
            else
            {
                $projectxCutList .= $$offset{'rs'}[0]{'offset'} . "\n";
            }
        }
    }

    ## CutList file
    ## my $cutListFile = $tempDir . "/" . $chanId . "_" . $startTime . "/" . $chanId . "_" . $startTime . ".cut";

    ## Write cutListFile
    open (CUT, ">> $cutListFile")
    or abnormalExit("Could not write cut list to " . $cutListFile);
    print CUT $projectxCutList;
    close (CUT)
    or abnormalExit("Could not close cut list file " . $cutListFile);

    return 1;
}

sub getRecordingInfo
{
    my ($fileDir, $fileName) = @_;

    ## Establish DB connection
    my $db = getDBConnection();

    ## Fetch recorded info
    my $sql             = "SELECT title, subtitle, season, episode FROM recorded WHERE basename='" . $fileName . "';";
    my $recordingInfo   = execSQL($sql);

    if (! $$recordingInfo{'rc'} )
    {
        abnormalExit("RC: " . $$recordingInfo{'rc'} . " - No recording Info for $fileDir/$fileName found!");
    }

    toLog("Title: '" . $$recordingInfo{'rs'}[0]{'title'} . "', Subtitle: '" . $$recordingInfo{'rs'}[0]{'subtitle'} . "', Season: '" . $$recordingInfo{'rs'}[0]{'season'} . "', Episode: '" . $$recordingInfo{'rs'}[0]{'episode'} . "'", "INFO");

    return $$recordingInfo{'rs'}[0];
}

sub getMediaInfo
{
    my ($fileDir, $fileName) = @_;
    my (%mediaInfo, $cmd);

    ## Fetch track information
    toLog("Starting mediainfo to retrieve track info", "INFO");

    ## Retrieve video track id
    $cmd = 'nice -n ' . $niceValue . ' ' . $$requiredPrograms{'mediainfo'} . ' --Output="Video;%ID%" ' . $fileDir . '/' . $fileName . ' 2>&1';
    toLog("Executing: $cmd", "VERB") if ($verbose);

    $output = `$cmd`;
    chomp($output);
    toLog($output, 'VERB') if ($verbose);
    abnormalExit("mediainfo exited with errors on fetching track information, run " . $scriptName . " --verbose and check logfile " . $logFile . " for errors.") if ($? != 0);

    $mediaInfo{'video'} = $output;

    ## Retrieve video height (480, 720, 1080, etc)
    $cmd = 'nice -n ' . $niceValue . ' ' . $$requiredPrograms{'mediainfo'} . ' --Output="Video;%Height%" ' . $fileDir . '/' . $fileName . ' 2>&1';
    toLog("Executing: $cmd", "VERB") if ($verbose);

    $output = `$cmd`;
    chomp($output);
    toLog($output, 'VERB') if ($verbose);
    abnormalExit("mediainfo exited with errors on fetching track information, run " . $scriptName . " --verbose and check logfile " . $logFile . " for errors.") if ($? != 0);

    $mediaInfo{'vheight'} = $output;

    ## Fetch FPS
    $cmd = 'nice -n ' . $niceValue . ' ' . $$requiredPrograms{'mediainfo'} . ' --Output="Video;%FrameRate%" ' . $fileDir . '/' . $fileName . ' 2>&1';
    toLog("Executing: $cmd", "VERB") if ($verbose);

    $output = `$cmd`;
    chomp($output);
    toLog($output, 'VERB') if ($verbose);
    abnormalExit("mediainfo exited with errors on retrieving fps, run " . $scriptName . " --verbose and check logfile " . $logFile . " for errors.") if ($? != 0);

    $mediaInfo{'fps'} = $output;

    ## Fetch Codec
    $cmd = 'nice -n ' . $niceValue . ' ' . $$requiredPrograms{'mediainfo'} . ' --Output="Video;%Codec%" ' . $fileDir . '/' . $fileName . ' 2>&1';
    toLog("Executing: $cmd", "VERB") if ($verbose);

    $output = `$cmd`;
    chomp($output);
    toLog($output, 'VERB') if ($verbose);
    abnormalExit("mediainfo exited with errors on retrieving codec, run " . $scriptName . " --verbose and check logfile " . $logFile . " for errors.") if ($? != 0);

    $mediaInfo{'Codec'} = $output;

    ## Retrieve info about audio tracks
    $cmd = 'nice -n ' . $niceValue . ' ' . $$requiredPrograms{'mediainfo'} . ' --Output="Audio;%ID%,%Format%,%Channel(s)%,%BitRate%,%Language%\n" ' . $fileDir . '/' . $fileName . ' 2>&1';
    toLog("Executing: $cmd", "VERB") if ($verbose);

    $output = `$cmd`;
    toLog($output, 'VERB') if ($verbose);
    abnormalExit("mediainfo exited with errors on getting audio tracks, run " . $scriptName . " --verbose and check logfile " . $logFile . " for errors.") if ($? != 0);

    toLog("mediainfo finished", "INFO");

    my $trackPos = 0;

    foreach (split /\n/, $output)
    {
        my ($id, $streamType, $channels, $bitrate, $language) = split /,/, $_;

        $trackPos++;

        $streamType = 'unknown' if ($streamType !~ m/MPEG Audio|AC-3/);
        $streamType = 'ac3'     if ($streamType =~ m/AC-3/);
        $streamType = 'mp2'     if ($streamType =~ m/MPEG Audio/);

        ## Set audio stream priority
        my $streamPriority;
        $streamPriority     = 1 if ($streamType =~ m/ac3/);     # ac3 priority 1
        $streamPriority     = 2 if ($streamType =~ m/mp2/);     # mp2 priority 2 (if equal amount of channels, prefer mp2)
        $streamPriority     = 3 if ($streamType !~ m/ac3|mp2/); # any other filetype I don't know has priority 0 :)

        ## Only add stream to audio list if all variables are set
        if ($id && $streamType && $channels && $bitrate && $language)
        {
            $mediaInfo{'audio'}{$id} = {    'streamType'        => $streamType,
                                            'channels'          => $channels,
                                            'bitrate'           => ($bitrate / 1000), # we need a kbit value
                                            'language'          => $language,
                                            'trackPos'          => $trackPos,
                                            'streamPriority'    => $streamPriority
                                        };
            toLog($id . " --> " . 'streamType: ' . $streamType . ' streamPriority: ' . $streamPriority . "\n\n", 'VERB') if ($verbose);
        }
    }

    ## Boil down to the really needed audio streams in the encoded file
    ##
    ## Prefer 2 channel mp2 over 2 channel ac3.
    ## Prefer 6 channel audio over 2 channel audio.
    ## Prefer 8 channel audio over 6 channel audio.
    ## Keep languages as well by still following rules above.

    my @skipLanguages = split /,/, $skipLang;

    foreach my $streamId (keys %{$mediaInfo{'audio'}})
    {
        ## Check if streamId was deleted before
        next if ( ! exists $mediaInfo{'audio'}{$streamId} );

        # Delete audio track from list if this language shall be skipped
        if (in_array($mediaInfo{'audio'}{$streamId}{'language'}, \@skipLanguages))
        {
            delete $mediaInfo{'audio'}{$streamId};
            next;
        }

        foreach my $cStreamId (keys %{$mediaInfo{'audio'}})
        {
            ## Skip if comparing with itself
            next if ($cStreamId == $streamId);

            ## Check if streamId was deleted before
            next if ( ! exists $mediaInfo{'audio'}{$cStreamId} || ! exists $mediaInfo{'audio'}{$streamId} );

            if ($mediaInfo{'audio'}{$streamId}{'streamPriority'} > $mediaInfo{'audio'}{$cStreamId}{'streamPriority'} &&
                $mediaInfo{'audio'}{$streamId}{'language'} eq  $mediaInfo{'audio'}{$cStreamId}{'language'}
            )
            {
                if ($mediaInfo{'audio'}{$streamId}{'channels'} >= $mediaInfo{'audio'}{$cStreamId}{'channels'})
                {
                    delete $mediaInfo{'audio'}{$cStreamId};
                }
                else
                {
                    delete $mediaInfo{'audio'}{$streamId};
                }
            }
        }
    }

    return \%mediaInfo;
}

#sub writeXini
#{
#    ## Write cutListFile
#    open (INI, ">> $projectxIniFile") or return 0;
#    print INI "SubtitlePanel.exportAsVobSub=1\nSubtitlePanel.TtxPage1=150\n";
#    close (INI) or return 0;
#
#    return 1;
#}

sub cleanup
{
    my ($workDir, $fileOwner, $targetFile) = @_;

    ## Delete working directory
    if ($workDir ne '')
    {
        $output = `rm -r $workDir 2>&1`;

        if ($? != 0)
        {
            toLog("Failed to delete " . $workDir ." : " . $!, "ERROR");
        }
    } else
    {
        toLog("Not deleting empty \$workdir variable. There's something wrong.. :(", "ERROR");
    }

    ## Set ownership
    if ($fileOwner ne '')
    {
        my $execUser = `whoami`;
        chomp($execUser);

        if ($execUser !~ m/root/)
        {
            my $chownCommand = `which chown`;
            chomp($chownCommand);

            $output = `sudo -ln $chownCommand $fileOwner "$targetFile" >/dev/null 2>&1`;

            if ($? == 0)
            {
                $output = `sudo $chownCommand $fileOwner "$targetFile" 2>&1`;

                if ($? != 0)
                {
                    toLog("Failed to set preferred file owner: " . $!, "ERROR");
                }
            } else
            {
                toLog("Failed to set preferred file owner '$fileOwner'.", "ERROR");
                toLog("The user '$execUser' executing this script is neither root nor the use of \"sudo $chownCommand $fileOwner '$targetFile'\" is allowd by sudoers.", "ERROR");
            }
        } else
        {
            toLog("Setting preferred file owner '$fileOwner' to encoded file", "INFO");
            $output = `chown $fileOwner "$targetFile" 2>&1`;

            if ($? != 0)
            {
                toLog("Failed to set preferred file owner: " . $!, "ERROR");
            }
        }
    }
}

sub checkOptions
{
    my ($chanId, $startTime, $fileDir, $fileName, $quality, $verbose, $scriptName, $videoQualityDefault) = @_;
    my $failedChecks = 0;

    if ($chanId eq '' || $chanId =~ /\D/)
    {
        toLog("chanid not set or invalid", "FATAL");
        $failedChecks++;
    }

    if ($startTime eq '' || $startTime =~ /\D/)
    {
        toLog("starttime not set or invalid", "FATAL");
        $failedChecks++;
    }

    if ($fileDir eq '')
    {
        toLog("directory not set or invalid", "FATAL");
        $failedChecks++;
    }

    if ($fileName eq '')
    {
        toLog("filename not set or invalid", "FATAL");
        $failedChecks++;
    }

    if ($quality =~ /\D/ || $quality < 0 || $quality > 51)
    {
        toLog("constant quality value invalid", "FATAL");
        $failedChecks++;
    }

    if ($threads ne 'auto')
    {
        if ($threads ne '' && $threads !~ /[0-9]*\.?[0-9]*/)
        {
            toLog("thread value invalid", "FATAL");
            $failedChecks++;
        }

        if ($threads ne '' && $threads =~ /[0-9]*\.?[0-9]*/ && $threads > 128)
        {
            toLog("thread value invalid, a max. of 128 is allowed, but really ... you would not go that high :)", "FATAL");
            toLog("if unsure about which thread value to set, leave it unset. This will set this value to 'auto'.", "FATAL");
            $failedChecks++;
        }
    }

    if ($failedChecks > 0)
    {
        usage($scriptName, $videoQualityDefault);
        exit 1;
    }
}

sub usage
{
    my ($scriptName, $videoQualityDefault) = @_;

    my $usage = <<EOL;

Usage:  $scriptName --chanid=[int value] --starttime=[int value] --directory=[string value] --file=[string value] --quality=[int value] --verbose

        --chanid        MythTV CHANID [REQUIRED]
        --starttime     MythTV STARTTIME [REQUIRED]
        --directory     MythTV storage directory [REQUIRED]
        --file          MythTV filename of recording [REQUIRED]
        --quality       Constant Quality factor [51..0] used by handbrake
                        Look up 'https://trac.handbrake.fr/wiki/ConstantQuality'
                        for more information
                        [OPTIONAL] defaults to $videoQualityDefault
        --threads       Number of threads x264 will utilize for encoding
                        Look up 'http://mewiki.project357.com/wiki/X264_Settings#threads'
                        for more information
                        [OPTIONAL] integer / floating point number, defaults to 'auto'
        --noCrop        Disable auto image cropping by handbrake
                        [OPTIONAL] toggle
        --verbose       Write output of mythtranscode, handbrake and mkvmerge to logfile
                        [OPTIONAL] toggle

        For installation as mythtv user job, it may be called like this:
        ../myth_make_x264.pl --chanid=%CHANID% --starttime=%STARTTIME% --directory=%DIR% --file=%FILE% --threads=1

EOL

    toLog($usage, "USAGE");
}

sub checkDaylightSavingsTime
{
    my $day     = $_[0];
    my $month   = $_[1];
    my $weekday = $_[2];

    # Check to see if the daylight savings time is currently in effect.
    # It starts the first Sunday in April and ends the last Sunday in October.

    # Initialize variables
    my ($daylightSavingsTime,$apr,$oct) = (0,3,9);

    if ($month > $apr && $month < $oct) {
        $daylightSavingsTime = 1;
    }
    elsif ($month == $apr)
    {
        $daylightSavingsTime = 1 if ($day - $weekday) >= 1;
    }
    elsif ($month == $oct)
    {
        my $daysUntilSunday = (7 - $weekday);
        $daylightSavingsTime = 1 if ($day + $daysUntilSunday) <= 31;
    } # end if

    return ($daylightSavingsTime);
}

sub seconds_to_hms
{
    my $timestamp = shift;

    my $hours = int($timestamp / 3600);
    $timestamp -= $hours * 3600;
    my $minutes = int($timestamp / 60);
    $timestamp -= $minutes * 60;
    my $whole_seconds = int($timestamp);
    my $milliseconds = 1000 * ($timestamp - $whole_seconds);

    return sprintf("%02d:%02d:%02d.%03d", $hours, $minutes, $whole_seconds, $milliseconds);
}
