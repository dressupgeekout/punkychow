#!/usr/bin/env ruby
#
# Copyright 2021 Charlotte Koch.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice,
# this list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright notice,
# this list of conditions and the following disclaimer in the documentation
# and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
#

require 'json'
require 'socket'

puts "=== Loading GStreamer gem ==="
require 'gstreamer'

class Application
  SOUND_DEVICE = "/dev/sound"

  # Runtime user-settable parameters
  attr_accessor :bass_gain
  attr_accessor :mid_gain
  attr_accessor :treble_gain

  # The individual elements of the GStreamer pipeline
  attr_reader :input_device
  attr_reader :raw_audio_parse
  attr_reader :eq
  attr_reader :audioconvert
  attr_reader :audioresample
  attr_reader :sink

  # GStreamer/GLib fun
  attr_reader :pipeline
  attr_reader :main_loop
  attr_reader :control_thread

  def initialize
    @bass_gain = 0
    @mid_gain = 0
    @treble_gain = 0
    @done = false

    @bands = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

    note "Setting audio device parameters"
    # XXX not sure if we can figure this out automatically?
    # system %Q(audiocfg default 0)

    # Set the sound(4) device parameters to some known values.
    #
    # These parameters are limited by the capabilities of the hardware.
    system %Q(audioctl -d #{SOUND_DEVICE} -w record.encoding=slinear_le)
    system %Q(audioctl -d #{SOUND_DEVICE} -w record.precision=16)
    system %Q(audioctl -d #{SOUND_DEVICE} -w record.rate=48000)
    system %Q(audioctl -d #{SOUND_DEVICE} -w record.channels=1)
    system %Q(audioctl -d #{SOUND_DEVICE} -w play.encoding=slinear_le)
    system %Q(audioctl -d #{SOUND_DEVICE} -w play.precision=16)
    system %Q(audioctl -d #{SOUND_DEVICE} -w play.rate=48000)
    system %Q(audioctl -d #{SOUND_DEVICE} -w play.channels=1)

    note "Initializing GStreamer"
    Gst.init
  end

  def note(str)
    puts "=== #{str} ==="
  end

  def set_bass(val)
    puts "SET BASS GAIN #{@bass_gain} -> #{val}"
    @bass_gain = val
    @eq.set_property("band0", @bass_gain)
  end

  def set_mid(val)
    puts "SET MIDRANGE GAIN #{@mid_gain} -> #{val}"
    @mid_gain = val
    @eq.set_property("band1", @mid_gain)
  end

  def set_treble(val)
    puts "SET TREBLE GAIN #{@treble_gain} -> #{val}"
    @treble_gain = val
    @eq.set_property("band2", @treble_gain)
  end

  def setup
    report_version
    create_elements
    create_pipeline
    create_control_thread
  end

  def main
    begin
      @main_loop = GLib::MainLoop.new(nil, false)
      @pipeline.play
      @main_loop.run
    rescue Interrupt
      puts("Got interrupt!")
      note "Shutting down"
      @done = true
    ensure
      self.teardown
      return 0
    end
  end

  def teardown
    @main_loop.quit
    @pipeline.stop
    @control_thread.kill
  end

  def report_version
    version_pretty = Gst.version.join(".")
    puts "Using GStreamer #{version_pretty}"
  end

  def create_elements
    note "Creating pipeline elements"

    @input_device = Gst::ElementFactory.make("filesrc", "input_device")
    @input_device.set_property("location", SOUND_DEVICE)

    # These paramenters need to match our previous ones.
    @raw_audio_parse = Gst::ElementFactory.make("rawaudioparse", "raw_audio_parse")
    @raw_audio_parse.set_property("format", "pcm")
    @raw_audio_parse.set_property("pcm-format", "s16le")
    @raw_audio_parse.set_property("sample-rate", 48000)
    @raw_audio_parse.set_property("num-channels", 1)

    #@eq = Gst::ElementFactory.make("equalizer-3bands", "eq")
    #set_bass(0)
    #set_mid(0)
    #set_treble(0)
    @eq = Gst::ElementFactory.make("equalizer-10bands", "eq")
    @eq.set_property("band0", 12)
    @eq.set_property("band1", 10)
    @eq.set_property("band2", 8)
    @eq.set_property("band3", 6)
    @eq.set_property("band4", 4)
    @eq.set_property("band5", 2)
    @eq.set_property("band6", 1)
    @eq.set_property("band7", 0)
    @eq.set_property("band8", 0)
    @eq.set_property("band9", 0)

    @audioconvert = Gst::ElementFactory.make("audioconvert", "audioconvert")
    @audioresample = Gst::ElementFactory.make("audioresample", "audioresample")

    @sink = Gst::ElementFactory.make("jackaudiosink", "sink")
    @sink.server = "punkychow"
    @sink.connect = 0
  end

  def pipeline_elements
    return [
      @input_device,
      @raw_audio_parse,
      @eq,
      @audioconvert,
      @audioresample,
      @sink,
    ]
  end

  # Make a pipeline to store all these elements, then actually hook up
  # the elements in the correct order.
  def create_pipeline
    @pipeline = Gst::Pipeline.new
    @pipeline.add(*self.pipeline_elements)

    @input_device >> @raw_audio_parse >> @eq >> @audioconvert >> @audioresample >> @sink

    # Listen to playback events
    @pipeline.bus.add_watch do |bus, message|
      p [bus, message.type]
      # XXX need to be able to handle error
      # XXX is there such thing as EOF/EOS with /dev/sound ??
      true
    end
  end

  def create_control_thread
    @control_thread = Thread.new do
      server = TCPServer.new("0.0.0.0", 9999)
      until @done do
        client = server.accept
        msg = client.gets.chomp
        ok = true

	req = JSON.parse(msg)

	case req["method"]
	when "volumeup"
	  Thread.new { system %Q(mixerctl -w outputs.speaker++) }
	when "volumedown"
	  Thread.new { system %Q(mixerctl -w outputs.speaker--) }
        when "inputup"
	  Thread.new { system %Q(mixerctl -w record.mic++) }
	when "inputdown"
	  Thread.new { system %Q(mixerctl -w record.mix--) }
	when "set"
	  param = req["param"]
	  value = req["value"]
	  @eq.set_property(param, value)
        else
          $stderr.puts(">> unknown message: #{msg.inspect}")
          ok = false
        end

        if ok
          client.puts("OK")
        else
          client.puts("ERROR")
        end

        client.close
      end
    end
  end
end

########## ########## ##########

if $0 == __FILE__
  @app = Application.new
  @app.setup
  rv = @app.main
  exit rv
end
