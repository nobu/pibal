#! /usr/local/bin/ruby19

require 'tempfile'
require 'net/smtp'
require 'optparse'
require 'time'
require 'netrc'
require 'io/console'
require_relative 'tds01v'

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
  COMMAND = "gnuplot"
  def self.new(command = COMMAND)
    popen([command, "-", err:[:child, :out]], "r+b")
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
  DEFAULT_INTERVAL = 60
  DEFAULT_SPEED = Rational(100, 60)

  attr_reader :scale, :data
  attr_accessor :speed, :interval

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

  def initialize(speed = nil, interval = nil)
    @plot = nil
    @speed = speed || DEFAULT_SPEED
    @interval = interval || DEFAULT_INTERVAL
    @data = []
    clear
  end

  def open
    unless @plot
      @plot = Gnuplot.new
      @plot.command(<<-PRESET)
        set angles degree
        set style line 2 linewidth 1 linecolor rgbcolor "#c0c0c0
        set style line 3 linewidth 0 linecolor rgbcolor "#e0e0e0
        set grid polar 45 linestyle 2, linestyle 3
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
    sprintf("~%4d %4s %4.1f", z, DEGREE%deg, vel)
  end

  def results
    [
     " HGHT   TO  M/S",
     *@data.map {|info| result(info)}
    ]
  end

  IMAGE_EXTS = {
    'jpeg' => 'jpg',
    'gif' => 'gif',
    'png' => 'png',
  }

  def image(type, size = [240, 240], font = ["arial", 10])
    d = nil
    ext = IMAGE_EXTS[type] or raise "unknown type `#{type}'"
    Tempfile.open(%W"pibal .#{ext}") do |tmp|
      tmp.close
      command(<<-OUTPUT)
        set terminal push
        set terminal #{type} crop font "#{font.join(',')}" size #{size.join(',')}
        set output "#{tmp.path}"
      OUTPUT
      yield
      command(<<-OUTPUT)
        set output
        set terminal pop
      OUTPUT
      d = tmp.open.binmode.read
    end
    return d, ext
  end
end

class Mailer < Struct.new(:fromaddr, :toaddr, :host, :port, :user, :passwd, :authtype, :connection, :image_type)
  def initialize(fromaddr = nil, toaddr = [], *rest)
    super
    self.image_type ||= 'gif'
  end

  CONNECTION_TYPE = [:tls, :starttls]
  AUTHENTICATION_TYPE = {'plain' => :plain, 'clear' => :plain, 'login' => :login, 'cram' => :cram_md5}
  SERVER_PATTERN = %r"([^/]*)(?i:/(#{AUTHENTICATION_TYPE.keys.join('|')}))?@([^@:]+)(?::(\d+))?(!{1,2})"
  def server=(args)
    if args.size == 1
      args = SERVER_PATTERN.match(str = args.first) or raise ArgumentError, "invaid server `#{str}'"
      args = args.to_a
    end
    user, authtype, host, port, conn = *args
    if user and host
      self.user = user
      self.authtype = AUTHENTICATION_TYPE[authtype]
      self.host = host
      self.port = port.to_i
      self.connection = (CONNECTION_TYPE[conn.length - 1] if conn)
    else
      self.user = self.host = nil
    end
  end

  def body(data)
    if Array === data
      bodies = data.map do |d|
        h, b = body(d)
        [h, '', b].join("\n")
      end
      boundary_base = "_mp.#{Time.now.strftime("%H:%M:%S")}."
      begin
        boundary = "#{boundary_base}#{rand(10000000)}_"
        boundary_pat = /^--#{Regexp.quote(boundary)}(?:--)?$/
      end while bodies.any? {|s| boundary_pat =~ s}
      bodies.unshift('')
      header = "Content-Type: multipart/mixed; boundary=\"#{boundary}\""
      (body = bodies.join("\n\n--#{boundary}\n")).strip!
      body << "\n\n--#{boundary}--\n"
    else
      if Hash === data
        content_type = data[:content_type]
        charset = data[:charset]
        filename = data[:filename]
        data = data[:data]
      end
      if data.encoding == Encoding::ASCII_8BIT
        content_type ||=
          case filename
          when /\.gif$/i
            "image/gif"
          when /\.jpe?g$/i
            "image/jpeg"
          when /\.png$/i
            "image/png"
          else
            "application/octet-stream"
          end
      else
        content_type ||= "text/plain"
        unless charset
          if (text = data.dup.force_encoding(Encoding::US_ASCII)).valid_encoding?
            data = text
            charset = "us-ascii"
          elsif /jis|jp|cp932/i =~ (charset = data.encoding.name)
            data = data.encode(charset = "iso-2022-jp")
          else
            charset = data.encoding.name
          end
        end
      end
      if /^text\// =~ content_type
        header = "Content-Type: #{content_type}; charset=#{charset}"
        body = data
      else
        filename &&= "; filename=#{filename.dump}"
        header = ["Content-Type: #{content_type}",
                  "Content-Disposition: inline#{filename}",
                  'Content-Transfer-Encoding: base64']
        body = [data].pack('m')
      end
    end
    return header, body
  end

  def send(data, subject)
    if host = self.host and user = self.user
      passwd = Net::Netrc.load[host][user].password
    end
    if !(fromaddr = self.fromaddr) and (fromaddr = user) and !user.empty? and
        /@/ !~ user and !host.empty?
      fromaddr = "#{user}@#{host}"
    end
    header, body = body(data)
    mail = [
            "To: #{self.toaddr.join(", ")}",
            "From: #{fromaddr}",
            "Subject: #{subject}",
            'MIME-Version: 1.0',
            header, '', body
           ].join("\n")
    if host and !(toaddr = self.toaddr).empty?
      smtp = Net::SMTP.new(host, self.port)
      if self.connection
        smtp.__send__("enable_#{self.connection}")
      end
      smtp.start(Socket.gethostname, user, passwd, self.authtype) do |m|
        m.send_mail(mail, fromaddr, *toaddr)
      end
    else
      i = Dir.glob("mail-*.txt").grep(/\d+/) {$&.to_i}.max || 0
      begin
        open("mail-#{i+=1}.txt", IO::WRONLY|IO::EXCL|IO::CREAT) {|f| f.puts(mail)}
      rescue Errno::EEXIST
        i += 1
        retry
      end
    end
  end
end

def ask(prompt, ans = nil)
  STDOUT.print(prompt)
  while c = (ans ? STDIN.getch : STDIN.noecho {STDIN.getc})
    if ans and ans.include?(c)
      break
    elsif "\r\n".include?(c)
      c = nil
      break
    end
  end
  puts(c || "\r\n")
  c
end

speed = nil
interval = nil
port = nil
alarm = 3
view = true
wait = 0.2
opt = nil
mailopt = Mailer.new
ARGV.options do |o|
  opt = o
  opt.on("-i", "--interval=SEC", Integer, "measuring interval in seconds") {|i| interval = i}
  opt.on("-s", "--speed=M/min", Integer, "ascending meters in a minute", [50, 100]) {|i| speed = i}
  opt.on("-p", "--port=PORT", "TDS01V port") {|v| port = v}
  opt.on("-a", "--alarm=N", Integer, "alarms N times") {|i| alarm = i}
  opt.on("--[no-]view") {|v| view = v}
  opt.on("--wait=SEC", Float, "wait in view mode") {|v| wait = v}
  opt.on("--to=ADDR") {|s| mailopt.toaddr << s}
  opt.on("--from=ADDR") {|s| mailopt.fromaddr = s}
  opt.on("-I", "--image-type={GIF,JPEG,PNG}", PiBal::IMAGE_EXTS.keys) {|i| mailopt.image_type = i}
  opt.on("-M", "--[no-]sendmail[=user[/auth]@host[:port][!!]", Mailer::SERVER_PATTERN) {|s, *a| mailopt.server = a}
  opt.on("--default[=FILE]", "load default options from FILE") {|f| opt.load(f)}
  opt.parse! rescue opt.abort([$!.message, opt.to_s].join("\n"))
end
if ARGV == %w[-]
  ARGV.empty? or opt.abort("- and log files are mutual")
elsif ARGV.empty?
  puts opt
  exit
end

def mailopt.send(pibal, starttime)
  results = pibal.results.join("\n")
  image, ext = pibal.image(type = self.image_type) {pibal.plot}
  image = {data: image, content_type: "image/#{type}", filename: "pibal.#{ext}"}
  super([results, image], "pibal #{starttime.strftime("%H:%M:%S")}")
end

if ARGV.empty?
  if tty = STDOUT.tty?
    clear_line = "\r\e[K"
    cr = "\r"
  else
    clear_line = cr = ""
  end
  tds = TDS01V.new(port) rescue opt.abort("failed to open port #{port}")
  PiBal.session(speed, interval) do |pibal|
    z = (interval = pibal.interval) * (speed = pibal.speed)
    alarm_cnt = [alarm, interval-1].min
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
        mmin = speed * 60
        if mmin.numerator == 1
          mmin = mmin.denominator
        end
        log.puts("#{starttime} (#{mmin} m/min)")
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
            SOUNDS.play(0) if interval - n < alarm_cnt
            print x, cr
          end
        end
      end
    rescue StopIteration, EOFError
    end
    watcher.kill
    print clear_line
    mailopt.send(pibal, starttime)
    /y/i =~ ask("Continue? [Y/n]", "YyNn")
  end
else
  PiBal.session() do |pibal|
    firstline = ARGF.gets or break
    unless speed = firstline[/(\d+)(?:\/(\d+))?\s*m\/min/, 1]
      ARGF.close
      opt.warn "missing acsending speed in #{ARGF.filename}"
      redo
    end
    pibal.speed = Rational(speed.to_i, ($2 ? $2.to_i : 1) * 60)
    starttime = Time.parse(firstline)
    puts pibal.title
    ARGF.each_line do |line|
      line.chomp!
      z, azim, elev = line.split(" ", 4)
      pibal.add(z.to_i, azim.to_f, elev.to_f)
      puts pibal.info
      if view
        pibal.plot
        sleep wait
      end
      break if ARGF.eof?
    end
    mailopt.send(pibal, starttime)
    ask("Hit return to go next.") if view
    true
  end
end
