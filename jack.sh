set -ex

SOUND_DEVICE=/dev/sound

# It's just the name of the jackd instance
export JACK_DEFAULT_SERVER=punkychow

audioctl -d ${SOUND_DEVICE} -w record.encoding=slinear_le
audioctl -d ${SOUND_DEVICE} -w record.precision=16
audioctl -d ${SOUND_DEVICE} -w record.rate=48000
audioctl -d ${SOUND_DEVICE} -w record.channels=1
audioctl -d ${SOUND_DEVICE} -w play.encoding=slinear_le
audioctl -d ${SOUND_DEVICE} -w play.precision=16
audioctl -d ${SOUND_DEVICE} -w play.rate=48000
audioctl -d ${SOUND_DEVICE} -w play.channels=1

jackd \
	-v -r -d sun \
	--rate 48000 --wordlength 16 --inchannels 1 --outchannels 1 -C /dev/sound -P /dev/sound

# Make sure that the 'capture' port isn't connected to the 'playback' port. We
# don't actually want to listen to the input directly; we only want to hear the
# result as it's processed w/ GStreamer.
jack_disconnect system:capture_1 system:playback_1 || : 
