#!/bin/bash
usage="usage: $0 t|f outputfile.wav my-program

Tries to record the audio output of my-program to outputfile.wav with
as little disturbance to the audio system as possible.

* t: timid behaviour: risks not recording all output, but less impact on
     rest of audio system and less risk of recording something you don't
     want to record
* f: force: During the whole time of the recording, the default audio
     output goes to the file. So you may record too much and steal audio
     from too many programs, but you won't record too little.

CAVEATS:
* It globally changes the default audio output for a while.
* If the program closes its audio output and opens a new one,
  that won't be recorded.
* This relies on PulseAudio, it won't work with jack or pure alsa."


# check $1 parameter
if test "$1" = "t"; then
	behaviour=t
elif test "$1" = "f"; then
	behaviour=f
else
	echo "error: first argument is supposed to be either t or f, but its \"$1\""
	echo "$usage"
	exit 1
fi

# check $2 parameter
outputfile="2"
if test ! -d $(dirname $outputfile); then
	echo "error: Output directory doesn't exist: $(dirname $outputfile)"
	echo "$usage"
	exit 1
fi

# check $3 parameter
program="$3"
if test ! -x "$(which "$program")"; then
	echo "error: Program doesn't exist or is not executable: $program"
	echo "$usage"
	exit 1
fi

# check further parameters
if test -n "$4"; then
	echo "error: there are too many arguments, recognized only $1 $2 $3"
	echo $usage
	exit 1
fi

# is the required module loaded?
if test ! -n "$(grep -e '^snd_aloop' /proc/modules)" ; then
	echo "error: snd_aloop is not loaded, please load it with 'modprobe snd_aloop'"
	echo "$usage"
	exit 1
fi


realDefaultSink=$(pacmd list-sinks | grep -A 1 '  \* index: ' | grep -oe '[^\<\>]*' | tail -n 1)
if test ! -n "$realDefaultSink"; then
	echo "error: failed to determine default sink"
	exit 1
fi

# set default sink to loopback so the newly started $program uses that sink
# I hardcoded that name, hopefully that's always the same
if pacmd set-default-sink alsa_output.platform-snd_aloop.0.analog-stereo; then
	echo "Changed default sink to loopback, don't start other programs now
or they might interfer with your recording."
else
	echo "error: failed to set default sink to loopback"
	exit 1
fi

# start recording
parec --file-format=wav -d alsa_output.platform-snd_aloop.0.analog-stereo.monitor "$outputfile" &
recordingPID=$!

# start the application
"$program" &

# get the pid of the application
applicationPID=$!

# set to true if application dies before the kill statement later
died="false"

if test "$behaviour" = "f"; then
	wait $applicationPID
	died="true"
elif test "$behaviour" = "t"; then
	# wait until the application uses audio (with the modified default sink)
	searching="true"
	while test "true" = "$searching"; do
		applicationPIDchildren="$(pgrep -P $applicationPID)" # get children of $applicationPID
		for pid in $applicationPID $applicationPIDchildren; do
			if test "$(pacmd list-sink-inputs | grep 'application.process.id' | grep -oe "$pid")" = "$pid"; then
				# one of the pids is using a sink
				echo "$program ($applicationPID) started using sound with pid $pid."
				searching="false"
			fi
		done
		# otherwise this would run as often as possible and probably use
		# quite some resources. That way the default sink is wrong for
		# another 0.1 seconds at most.
		sleep 0.1
		kill -0 $applicationPID || (
			echo "error: application quit without outputting sound
       (at least that I know of)"
			break
			died="true"
		)
	done
else
	echo "Impossible, I checked."
fi

# set default sink back to what it was before
if pacmd set-default-sink "$realDefaultSink"; then
	echo "Changed default sink back to what it was before,
starting other programs should be safe now."
else
	echo "error: failed to reset default sink to $realDefaultSink"
	exit 1
fi

# wait until the application closes unless it already died
test "true" = $died || wait $applicationPID

# stop recording
if kill "$recordingPID"; then
	echo "Stopped recording, success is probable."
else
	echo "error: failed to stop recording, might still be recording!"
	exit 1
fi

exit 0
