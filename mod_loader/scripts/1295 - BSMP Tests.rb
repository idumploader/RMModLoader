#==============================================================================
# BSMP Tests — console unit tests for the parts of BSMP that are pure enough to
# verify on one machine, no second Steam account, no networking. Run on a map:
#
#   bsmp_test             run everything
#   bsmp_test_handshake   only BSMP::Handshake.validate verdicts
#   bsmp_test_world       only the BSMP::World dump/apply roundtrip
#
# Each prints PASS/FAIL per case and a summary; the runner returns true iff all
# passed. The interactive remote-player harness lives separately (TestGhost).
#
# Gate: only loads when BSMP is defined.
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-Tests"]
$imported["IDL-BSMP-Tests"] = "1.0"

if not defined?(BSMP)
p "BSMP isn't loaded, tests unavailable"
else

module BSMPTests

  H = BSMP::Handshake
  W = BSMP::World

  # --- runners -------------------------------------------------------------

  def self.run_all
    reset
    run_section("handshake") { handshake_cases }
    run_section("world")     { world_cases }
    summary
  end

  def self.run_handshake
    reset
    run_section("handshake") { handshake_cases }
    summary
  end

  def self.run_world
    reset
    run_section("world") { world_cases }
    summary
  end

  # --- tiny framework ------------------------------------------------------

  def self.reset
    @pass = 0
    @fail = 0
  end

  def self.run_section(name)
    p "[#{name}]"
    yield
  end

  def self.expect(name, cond)
    if cond
      @pass += 1
      p "  PASS  #{name}"
    else
      @fail += 1
      p "  FAIL  #{name}"
    end
  end

  def self.summary
    p "BSMP tests: #{@pass} passed, #{@fail} failed"
    @fail == 0
  end

  # --- handshake cases -----------------------------------------------------

  def self.handshake_cases
    if not W.ready?
      return p "  SKIP  load a game first (needs $data_*)"
    end

    base = H.parse(H.hello) # a peer identical to us

    expect("self hello accepts",        accepts?(base))
    expect("major mismatch rejects",    rejects?(base.merge(:major => base[:major] + 1)))
    expect("peer minor out of our range rejects", rejects?(base.merge(:minor => 99)))
    expect("peer rejects our minor",    rejects?(base.merge(:accept_min => 5, :accept_max => 5)))

    in_range = pick_in_range_minor(base)
    if in_range
      expect("minor differs but mutually accepted", accepts?(base.merge(:minor => in_range)))
    else
      p "  SKIP  minor-differs (accepted range has no value != ours)"
    end

    expect("game mismatch rejects", rejects?(base.merge(:game_title => base[:game_title].to_s + "X")))

    bad_hash = base.merge(:data_hash => base[:data_hash] ^ 1)
    with_data_hash_check(true)  { expect("hash mismatch rejects (gate on)",  rejects?(bad_hash)) }
    with_data_hash_check(false) { expect("hash mismatch passes (gate off)", accepts?(bad_hash)) }
  end

  def self.accepts?(peer); H.validate(peer)[0] == true;  end
  def self.rejects?(peer); H.validate(peer)[0] == false; end

  def self.pick_in_range_minor(base)
    (BSMP::Config::ACCEPTED_MINOR_MIN..BSMP::Config::ACCEPTED_MINOR_MAX).find { |m| m != base[:minor] }
  end

  # Flip Config::CHECK_DATA_HASH without the "already initialized constant" warning,
  # restoring it even if the block raises.
  def self.with_data_hash_check(value)
    old = BSMP::Config::CHECK_DATA_HASH
    set_data_hash_check(value)
    begin
      yield
    ensure
      set_data_hash_check(old)
    end
  end

  def self.set_data_hash_check(value)
    BSMP::Config.send(:remove_const, :CHECK_DATA_HASH)
    BSMP::Config.const_set(:CHECK_DATA_HASH, value)
  end

  # --- world cases ---------------------------------------------------------

  # dump A -> mutate the live world hard -> load(A) -> dump B; lossless apply means
  # A == B byte-for-byte. Unsupported-typed variables are excluded from BOTH dumps,
  # so they never cause a false fail. The world is restored to its start (A applied),
  # so this is non-destructive.
  def self.world_cases
    if not W.ready?
      return p "  SKIP  load a game first (needs $game_*)"
    end

    a      = W.dump
    packed = BSMP::Wire.pack(a)

    mutate_world
    loaded = W.load(a)
    b      = W.dump

    ratio = a.bytesize > 0 ? (packed.bytesize * 100 / a.bytesize) : 0
    p "  size: #{a.bytesize} B raw -> #{packed.bytesize} B on wire (#{ratio}%); " \
      "sw=#{W.switch_count} var=#{W.variable_count} ss=#{self_switch_count}"

    expect("load returned true", loaded == true)
    equal = (a == b)
    expect("dump/apply roundtrip is lossless", equal)
    if not equal
      p "  -> sizes A=#{a.bytesize} B=#{b.bytesize}, first diff at byte #{first_diff(a, b)}"
    end
  end

  def self.mutate_world
    (1..W.switch_count).each { |i| $game_switches[i] = !$game_switches[i] }
    (1..W.variable_count).each do |i|
      v = $game_variables[i]
      $game_variables[i] = v + 1 if v.is_a?(Integer)
    end
    $game_self_switches[[999_999, 1, "A"]] = true
    $game_self_switches[[999_999, 2, "D"]] = true
  end

  def self.self_switch_count
    data = W.self_switch_data
    data ? data.values.count { |v| v } : 0
  end

  def self.first_diff(a, b)
    n = [a.bytesize, b.bytesize].min
    i = 0
    while i < n
      return i if a.getbyte(i) != b.getbyte(i)
      i += 1
    end
    a.bytesize == b.bytesize ? -1 : n
  end

end

def bsmp_test
  BSMPTests.run_all
end

def bsmp_test_handshake
  BSMPTests.run_handshake
end

def bsmp_test_world
  BSMPTests.run_world
end

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-Tests"]
