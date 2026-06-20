#==============================================================================
# BSMP World — part 1b/5: world-state serialization. Turns the host-canonical
# shared world ($game_switches / $game_variables / $game_self_switches) into a
# compact binary blob and back, for the join-time world dump (and later the
# session write-back). No Marshal (RCE-safe); the transport zlib-compresses the
# blob automatically once it crosses the size threshold. See 1200 - BSMP Core.rb.
#
# Format (version-tagged, little bit-twiddling, all ints LEB128 varint):
#   u8   FORMAT
#   switches:     varint N, then ceil(N/8) packed bits (index 1..N)
#   variables:    varint COUNT, then COUNT * [varint index, value]
#                   value = u8 tag + payload; recursive. Tags: 0 int (zigzag),
#                   1 string (len+bytes), 2 array (count + values), 3 true, 4 false,
#                   5 nil, 6 float (8 B LE). Unknown classes -> logged, stored as nil.
#   self-switches: varint COUNT, then COUNT * [varint map_id, varint event_id, u8 ch]
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-World"]
$imported["IDL-BSMP-World"] = "1.0"

if defined?(BSMP)

module BSMP

  module World

    # Bump when the wire layout below changes incompatibly.
    FORMAT = 2

    SELF_SWITCH_CHARS = "ABCD"

    # True once a game is actually loaded (the $game_* objects exist). Handshake
    # must not dump/apply from the title screen.
    def self.ready?
      $game_switches and $game_variables and $game_self_switches and $data_system
    end

    # --- serialize -----------------------------------------------------------

    def self.dump
      w = "".force_encoding("ASCII-8BIT")
      w << [FORMAT].pack("C")
      dump_switches(w)
      dump_variables(w)
      dump_self_switches(w)
      w
    end

    def self.dump_switches(w)
      n = switch_count
      write_uint(w, n)
      bytes = Array.new((n + 7) / 8, 0)
      (1..n).each do |i|
        bytes[(i - 1) >> 3] |= (1 << ((i - 1) & 7)) if $game_switches[i]
      end
      w << bytes.pack("C*")
    end

    def self.dump_variables(w)
      indices = (1..variable_count).select { |i| $game_variables[i] != 0 }
      write_uint(w, indices.size)
      indices.each do |i|
        write_uint(w, i)
        encode_value(w, $game_variables[i])
      end
    end

    def self.dump_self_switches(w)
      data = self_switch_data
      trues = data ? data.select { |_, v| v } : {}
      write_uint(w, trues.size)
      trues.each do |key, _|
        map_id, event_id, ch = key
        write_uint(w, map_id)
        write_uint(w, event_id)
        w << [SELF_SWITCH_CHARS.index(ch) || 0].pack("C")
      end
    end

    # --- deserialize (full replace; host world is canonical) -----------------

    def self.load(blob)
      return false if not ready?
      r = Reader.new(blob)
      format = r.u8
      if format != FORMAT
        p "BSMP::World: snapshot format #{format} != #{FORMAT}, ignoring"
        return false
      end
      # Applying the snapshot writes thousands of switches/vars; guard so the
      # live-sync setter hooks don't re-broadcast each one as a fact.
      $bsmp_applying_fact = true
      begin
        load_switches(r)
        load_variables(r)
        load_self_switches(r)
      ensure
        $bsmp_applying_fact = false
      end
      $game_map.need_refresh = true if $game_map
      true
    end

    def self.load_switches(r)
      n = r.uint
      raw = r.bytes((n + 7) / 8)
      (1..n).each do |i|
        bit = (raw.getbyte((i - 1) >> 3) >> ((i - 1) & 7)) & 1
        $game_switches[i] = (bit == 1)
      end
    end

    def self.load_variables(r)
      # Reset to default first so a guest's stray non-zero vars don't survive the
      # adoption of the host's world, then apply the host's non-zero set.
      (1..variable_count).each { |i| $game_variables[i] = 0 }
      count = r.uint
      count.times do
        i = r.uint
        $game_variables[i] = decode_value(r)
      end
    end

    # Recursive value codec for variable contents. Only ever constructs plain
    # Ruby primitives (no object instantiation from peer data), so it's RCE-safe
    # unlike Marshal.load.
    def self.encode_value(w, v)
      case v
      when Integer
        w << [0].pack("C")
        write_sint(w, v)
      when String
        b = v.dup.force_encoding("ASCII-8BIT")
        w << [1].pack("C")
        write_uint(w, b.bytesize)
        w << b
      when Array
        w << [2].pack("C")
        write_uint(w, v.size)
        v.each { |e| encode_value(w, e) }
      when TrueClass
        w << [3].pack("C")
      when FalseClass
        w << [4].pack("C")
      when NilClass
        w << [5].pack("C")
      when Float
        w << [6].pack("C")
        w << [v].pack("E") # 8-byte little-endian double
      else
        # Unknown class (Hash, Symbol, custom object): can't safely transfer.
        # Store as nil so the stream stays deterministic; log it.
        p "BSMP::World: unsupported value class #{v.class}, stored as nil"
        w << [5].pack("C")
      end
    end

    def self.decode_value(r)
      tag = r.u8
      case tag
      when 0 then r.sint
      when 1 then r.bytes(r.uint).force_encoding("UTF-8")
      when 2
        Array.new(r.uint) { decode_value(r) }
      when 3 then true
      when 4 then false
      when 5 then nil
      when 6 then r.bytes(8).unpack("E")[0]
      else nil
      end
    end

    def self.load_self_switches(r)
      data = self_switch_data
      data.clear if data # full replace; we re-add only the host's true ones
      count = r.uint
      count.times do
        map_id   = r.uint
        event_id = r.uint
        ch       = SELF_SWITCH_CHARS[r.u8, 1] || "A"
        $game_self_switches[[map_id, event_id, ch]] = true
      end
    end

    # --- counts / internals --------------------------------------------------

    def self.switch_count
      $data_system.switches.size - 1 # index 0 is unused
    end

    def self.variable_count
      $data_system.variables.size - 1 # index 0 is unused
    end

    def self.self_switch_data
      $game_self_switches.instance_variable_get(:@data)
    end

    # --- varint primitives ---------------------------------------------------

    # Unsigned LEB128.
    def self.write_uint(w, n)
      raise "write_uint: negative #{n}" if n < 0
      loop do
        b = n & 0x7F
        n >>= 7
        if n == 0
          w << [b].pack("C")
          break
        end
        w << [b | 0x80].pack("C")
      end
    end

    # Signed via zigzag (Bignum-safe: no fixed-width shift).
    def self.write_sint(w, n)
      write_uint(w, n >= 0 ? n * 2 : -n * 2 - 1)
    end

    # Cursor reader over a binary string.
    class Reader
      def initialize(str)
        @s = str.dup.force_encoding("ASCII-8BIT")
        @pos = 0
      end

      def u8
        b = @s.getbyte(@pos)
        @pos += 1
        b
      end

      def uint
        result = 0
        shift = 0
        loop do
          b = @s.getbyte(@pos)
          @pos += 1
          result |= (b & 0x7F) << shift
          break if (b & 0x80) == 0
          shift += 7
        end
        result
      end

      def sint
        z = uint
        z.even? ? z >> 1 : -((z + 1) >> 1)
      end

      def bytes(n)
        s = @s[@pos, n] || ""
        @pos += n
        s
      end

      def eof?
        @pos >= @s.bytesize
      end
    end

  end

end # module BSMP

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-World"]
