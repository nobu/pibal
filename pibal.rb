#! /usr/local/bin/ruby
STDOUT.sync = true

case RUBY_PLATFORM
when /darwin/
  SOUND_BASE = "/System/Library/Sounds/%s.aiff"
  SOUNDS = ["Ping", "Glass"]
  def SOUNDS.play(n)
    Process.detach(spawn("afplay", SOUND_BASE%self[n]))
  end
when /cygwin|mingw|mswin/
  SOUND_BASE = "c:/Windows/Media/Windows %s.wav"
  SOUNDS = ["Ding", "Exclamation"]
  def SOUNDS.play(n)
    #
  end
else
  SOUNDS = []
  def SOUNDS.play(n)
    #
  end
end

class Gnuplot < IO
  def self.new
    popen(["gnuplot", "-", err:[:child, :out]], "r+")
  end
  def command(lines)
    lines.each_line do |line|
      line.strip!
      s = self.gets(">")
      STDOUT.puts s.inspect if $VERBOSE
      self.puts(line)
    end
  end
end

class PiBal
  include Math
  DEG2RAD = PI / 180
  RAD2DEG = 180 / PI
  DEFAULT_SPEED = Rational(100, 60)

  attr_reader :scale, :data
  attr_accessor :speed

  def self.open(*args)
    pibal = new(*args)
    return pibal unless block_given?
    begin
      return yield(pibal)
    ensure
      pibal.close
    end
  end

  def self.session(*args)
    open(*args) do |pibal|
      while yield(pibal)
        pibal.clear
      end
    end
  end

  def clear
    @scale = 100
    @x0 = @y0 = @z0 = 0
    @data.clear
  end

  def initialize(speed = nil)
    @plot = nil
    @speed = speed || DEFAULT_SPEED
    @data = []
    clear
  end

  def open
    unless @plot
      @plot = Gnuplot.new
      @plot.command(<<-PRESET)
        set angles degree
        set grid polar 45
        set size square
        set zeroaxis
        set xtics axis nomirror scale 0 format ""
        set ytics axis nomirror scale 0 textcolor rgbcolor "#808080"
        set border 0
      PRESET
    end
    @plot
  end

  def close
    @plot.close if @plot
  end

  def command(*args)
    open.command(*args)
  end

  def plot(data = @data, scale = @scale)
    if scale > 0
      dec = 10 ** log10(scale).floor
      if (scale = (scale * 2 / dec).ceil) > 4
        scale = (scale + 1) & ~1
      end
      scale *= dec / 2
    end
    unit = scale > 1000 ? 1000.0 : 1
    scale /= unit
    command("scale = #{scale}")
    command('plot [-scale:scale][-scale:scale] "-" using 1:2:3:4 with vector lw 2 notitle')
    ok = false
    data.each do |a, e, x, y, z, dx, dy, *|
      next unless dx and dy
      command("%8.2f %8.2f %8.2f %8.2f" % [x/unit, y/unit, dx/unit, dy/unit])
      ok = true
    end
    command("0 0 0 0") unless ok
    command("e")
  end

  def add(z, azim, elev)
    x0 = @x0
    y0 = @y0
    z0 = @z0
    dx = dy = vel = 0
    if elev > 0
      rad_azim = azim * DEG2RAD
      rad_elev = elev * DEG2RAD
      dist = z / tan(rad_elev)
      x = dist * sin(rad_azim)
      y = dist * cos(rad_azim)
      dx = x - x0
      dy = y - y0
      dz = z - z0
      deg = (atan2(dx, dy) * RAD2DEG % 360 rescue nil)
      vel = hypot(dx, dy) / dz * @speed
      @x0, @y0, @z0 = x, y, z
      @scale = [@scale, dist].max
    end
    @data << [azim, elev, x0, y0, z, dx, dy, deg, vel]
  end

  Title = "Height  Azim  Elev       X(m)       Y(m)      dX(m)      dY(m)   To  M/s"
  def title
    self.class::Title
  end

  def (DEGREE = "%4.0f").%(f)
    f ? super : "N/A"
  end

  def info(info = @data.last)
    azim, elev, x, y, z, dx, dy, deg, vel = *info
    sprintf("%6d %5.1f %5.1f %10.2f %10.2f %10.2f %10.2f %4s %4.1f",
            z, azim, elev, x+dx, y+dy, dx, dy, DEGREE%deg, vel)
  end

  def result(info = @data.last)
    azim, elev, x, y, z, dx, dy, deg, vel = *info
    sprintf("~%.4d %4s %4.1f", z, DEGREE%deg, vel)
  end

  def results
    [
     " HGHT   TO  M/S",
     *@data.map {|info| result(info)}
    ]
  end

  def gif(size = [240, 240], font = ["arial", 10])
    require 'tempfile'
    d = nil
    Tempfile.open(%w"pibal .gif") do |tmp|
      tmp.close
      command(<<-OUTPUT)
        set terminal push
        set terminal gif crop font "#{font.join(',')}" size #{size.join(',')}
        set output "#{tmp.path}"
      OUTPUT
      yield
      command(<<-OUTPUT)
        set output
        set terminal pop
      OUTPUT
      d = tmp.open.read
    end
    d
  end
end

def ask(prompt, ans = "")
  STDOUT.print(prompt)
  while c = STDIN.noecho {STDIN.getc}
    if ans.include?(c)
      break
    elsif "\r\n".include?(c)
      c = nil
      break
    end
  end
  puts(c || "\r\n")
  c
end

def mailbody(text, binary)
  if binary
    boundary = "_mp.#{Time.now.strftime("%H:%M:%S")}.#{rand(10000000)}_"
    header = "Content-Type: multipart/mixed; boundary=\"#{boundary}\""
    binary, opt = *binary
    opt ||= {}
    if filename = opt[:filename]
      filename = "; filename=#{filename.dump}"
    end
    body = [
      "--#{boundary}",
      'Content-Type: text/plain; charset=US-ASCII',
      '', text,
      '',
      "--#{boundary}",
      "Content-Type: #{opt[:content_type]||"application/octet-stream"}",
      "Content-Disposition: inline#{filename}",
      'Content-Transfer-Encoding: base64',
      '',
      [binary].pack('m'),
      '',
      "--#{boundary}--",
      ''
    ].join("\n")
  else
    body = [text].join("\n")
  end
  return header, body
end

def mail(text, gifdata, opt)
  header, body = mailbody(text,
                          [gifdata, content_type: "image/gif", filename: "pibal.gif"])
  mail = [
    "To: #{opt[:toaddr].join(", ")}",
    "From: #{opt[:fromaddr]}",
    "Subject: pibal #{opt[:time].strftime("%H:%M:%S")}",
    'MIME-Version: 1.0',
    header, '', body
  ].join("\n")
  mail.gsub!(/\n/, "\r\n")
  yield mail
end

require 'io/console'
require 'optparse'

FROMADDR = "pibal@example.com"
speed = nil
interval = nil
alarm = 3
view = true
toaddr = []
fromaddr = FROMADDR
sendmail = false
opt = nil
ARGV.options do |o|
  opt = o
  opt.on("-i", "--interval=SEC", Integer, "measuring interval in seconds") {|i| interval = i}
  opt.on("-s", "--speed=M/min", Integer, "ascending meters in a minute", [50, 100]) {|i| speed = nil}
  opt.on("-a", "--alarm=N", Integer, "alarms N times") {|i| alarm = i}
  opt.on("--[no-]view") {|v| view = v}
  opt.on("--to=ADDR") {|s| toaddr << s}
  opt.on("--from=ADDR") {|s| fromaddr = s}
  opt.on("-M", "--[no-]sendmail") {|s| sendmail = s}
  opt.parse! rescue opt.abort([$!.message, opt.to_s].join("\n"))
end
if interval
  alarm = [alarm, interval-1].min
  ARGV.empty? or opt.abort("--interval and log files are mutual")
elsif ARGV.empty?
  puts opt
  exit
end

mailcount = 0
sendmail = sendmail ? proc do |pibal, starttime|
  results = pibal.results
  gifdata = pibal.gif {pibal.plot}
  mail(results, gifdata, fromaddr: fromaddr, toaddr: toaddr, time: starttime) do |m|
    open("mail-#{mailcount+=1}.txt", "wb") {|f| f.print(m)}
  end
end : proc {}

if ARGV.empty?
  require_relative 'tds01v'
  if tty = STDOUT.tty?
    clear_line = "\r\e[K"
    cr = "\r"
  else
    clear_line = cr = ""
  end
  tds = TDS01V.new
  PiBal.session(speed) do |pibal|
    z = interval * pibal.speed
    puts "ROM version = #{tds.rom_version * '.'}"
    watcher = Thread.start(Thread.current) do |main|
      ask("Hit enter to finish.\n") if tty
      main.raise(StopIteration)
    end
    pibal.plot if view
    puts pibal.title
    starttime = Time.now
    begin
      open("pibal-#{starttime.strftime("%Y%m%d_%H%M%S")}.log", "wb") do |log|
        log.puts("#{starttime} (#{speed * 60}m/min)")
        tds.enum_for(:start).with_index do |x, i|
          print clear_line
          n = (i + 1) % interval
          if n.zero?
            SOUNDS.play(1) if tty
            pibal.add((z * i), x.azimuth.fdiv(10), x.pitch.fdiv(10))
            pibal.plot if view
            info = pibal.info
            puts info
            log.puts info
          elsif tty
            SOUNDS.play(0) if interval - n < alarm
            print x, cr
          end
        end
      end
    rescue StopIteration, EOFError
    end
    print clear_line
    sendmail[pibal, starttime]
    /y/i =~ ask("Continue? [Y/n]", "YyNn")
  end
else
  require 'time'
  PiBal.session() do |pibal|
    firstline = ARGF.gets or break
    unless speed = firstline[/(\d+)m\/min/, 1]
      ARGF.close
      opt.warn "missing acsending speed in #{ARGF.filename}"
      redo
    end
    pibal.speed = Rational(speed.to_i, 60)
    starttime = Time.parse(firstline)
    puts pibal.title
    ARGF.each_line do |line|
      line.chomp!
      z, azim, elev = line.split(" ", 4)
      pibal.add(z.to_i, azim.to_f, elev.to_f)
      puts pibal.info
      if view
        pibal.plot
        sleep 0.2
      end
      break if ARGF.eof?
    end
    sendmail[pibal, starttime]
    ask("Hit return to go next.") if view
    true
  end
end
