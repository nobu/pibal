#! /usr/local/bin/ruby
require_relative 'tds01v'

port, int, max = TDS01V.parse_option(ARGV)
max -= 1
tds = TDS01V.new(port)
puts "ROM version = #{tds.rom_version * '.'}"
tds.enum_for(:start, int).with_index do |x, i|
  p x
  break if i >= max
end
