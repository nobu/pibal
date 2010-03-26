# -*- coding: utf-8 -*-
require 'serialport'
require 'thread'

class TDS01V
  DEVICE_PATTERN =
    case RUBY_PLATFORM
    when /darwin/
      "/dev/tty.usbserial-*"
    when /mswin|mingw/
    else
      "/dev/ttyUSB*"
    end

  DEVICES = DEVICE_PATTERN && Dir.glob(DEVICE_PATTERN)

  class NotAcknowledge < RuntimeError; end

  attr_accessor :declination, :standard_pressure

  def initialize(port = nil)
    if !port and DEVICES.size == 1
      port = DEVICES[0]
    end
    @port = SerialPort.new(port)
    @port.read_timeout = 1000
    @port.break(250)
  end

  EOL = "\r\n".freeze

  def req(str, ack = nil)
    @port.print(str, EOL)
    res = @port.gets(EOL) and res.chomp!(EOL) or raise EOFError, caller
    !ack or ack === res or raise NotAcknowledge, res, caller
    res
  end

  RESET_REQ = "0F"
  RESET_ACK = "F0"
  STATUS_REQ = "2B"
  STATUS_IDL = "00"
  def reset
    @port.break(250)
    ret = req(RESET_REQ) == RESET_ACK
    nil until req(STATUS_REQ) == STATUS_IDL
    ret 
  end

  ROMVERSION_REQ = "5F"
  def rom_version
    reset
    [req(ROMVERSION_REQ)].pack("H*").unpack("C*")
  end

  class Watcher < Queue
    alias get pop
  end

  def self.finalize(th, tds)
    th.kill
    tds.close
  end

  def close
    @port.close
  end

  def start(interval = 10, pressure = 1013.3, declination = 0)
    if block_given?
      raise ArgumentError, "oneshot but block given" unless interval > 0
    end
    reset
    # 計測条件設定
    req("05%.2X%.4X%.4X" % [interval, (pressure*10).to_i, declination.to_i], "FA")
    req("0DF7", "F2")           # センサ情報項目設定　全データ
    req("27", "D8")             # 地磁気センサ初期化
    req("21", "DE")             # 計測開始
    if interval > 0
      begin
        starttime = Time.now
        que = Watcher.new
        @running = th = Thread.start do
          t = interval
          loop do
            sleep(starttime + t.fdiv(10) - Time.now)
            t += interval
            que.push(get)
          end
        end
        if block_given?
          while data = que.pop
            yield data
          end
        else
          ObjectSpace.define_finalizer(que, self.class.finalize(th, self))
          th = nil
          que
        end
      ensure
        if th
          th.kill
          begin
            stop
          rescue NotAcknowledge
          end
        end
      end
    else
      get
    end
  end

  class << (STOP_OK = %W[DC 23])
    alias === include?
  end

  def stop
    retried = 0
    begin
      req("23", STOP_OK)
    rescue
      retry if (retried += 1) < 3
      raise
    end
  end

  Event = Struct.new(:mag, :azimuth, :acc, :roll, :pitch, :pressure, :altitude, :temperature, :voltage, :time)
  class Event
    def inspect
      "#<#{self.class.name}: mag=[#{mag.map{|x|'%d.%d'%x.divmod(10)}.join(", ")
        }] azimuth=#{'%d.%d'%azimuth.divmod(10)
        } acc=[#{mag.map{|x|'%d.%.2d'%x.divmod(100)}.join(", ")
        }] roll=#{'%d.%d'%roll.divmod(10)} pitch=#{'%d.%d'%pitch.divmod(10)
        } time=[#{time}]>"
    end

    def to_s
      "#{'%3d.%d'%azimuth.divmod(10)}/#{'%+3d.%d'%pitch.divmod(10)}"
    end
  end

  def get
    data = [req("29")].pack("H*").unpack("n*").pack("S*").unpack("s*")
    mag = data.shift(3)
    azimuth = data.shift
    acc = data.shift(3)
    Event.new(mag, azimuth, acc, *data, Time.now)
  end

  def self.parse_option(argv, opt = (require 'optparse'; OptionParser.new))
    port = nil
    max = 10
    int = 10
    opt.define("-p", "--port PORT") {|x| port = x}
    opt.define("-n", "--num MAX", Integer) {|x| max = x}
    opt.define("-i", "--interval TENTH-SECOND", Integer) {|x| int = x}
    (opt.parse!(argv).empty? rescue opt.warn) or abort(opt.help)
    return port, int, max
  end
end
