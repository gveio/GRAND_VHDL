library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.config_pkg.all;

entity pattern_generator is
  generic (
    LW_MAX : integer := 104;
    HW_MAX : integer := 13
  );
  port (
    clk, rst         : in  std_logic;
    gen_en           : in  std_logic; -- global enable for pattern generator
    pattern          : out std_logic_vector(HW_MAX * WIDTH_PATTERN - 1 downto 0);
    per_pattern_done : out std_logic;
    pattern_done     : out std_logic; -- all patterns for given LW,HW done
    abandon          : out std_logic; -- search abandoned at LW_max
    -- optional debug outputs
    LW_dbg           : out integer range 1 to LW_MAX;
    HW_dbg           : out integer range 1 to HW_MAX
  );
end entity;

architecture arch of pattern_generator is

  -- internal handshake signals
  signal LW_sig      : integer range 1 to LW_MAX;
  signal HW_sig      : integer range 1 to HW_MAX;
  signal abandon_sig : std_logic;
  signal done        : std_logic;
  signal gen_en_ls   : std_logic;

begin
  -- Global enable for landslide: stop when abandon='1'
  gen_en_ls <= gen_en and (not abandon_sig);

  -- LW / HW generation unit
  -- Uses done from Landslide to move to next LW/,HW pair
  -- Asserts abandon when LW_max reached
  u_lw_hw: entity work.lw_hw_generation_unit
    generic map (
      LW_MAX => LW_MAX,
      HW_MAX => HW_MAX
    )
    port map (
      clk          => clk,
      rst          => rst,
      gen_en       => gen_en, -- same global enable with top-level pattern generator
      pattern_done => done,   -- from Landslide unit
      LW           => LW_sig,
      HW           => HW_sig,
      abandon      => abandon_sig
    );

  -- Landslide unit
  -- Takes current LW_sig, HW_sig
  -- Generates all distinct integer partition-based patterns
  -- Pulses done when done with this LW,HW pair
  u_landslide: entity work.landslide_unit
    generic map (
      LW_MAX => LW_MAX,
      HW_MAX => HW_MAX
    )
    port map (
      clk          => clk,
      rst          => rst,
      gen_en       => gen_en_ls, -- disabled after abandon
      LW           => LW_sig,
      HW           => HW_sig,
      pattern      => pattern,
      per_pattern_done => per_pattern_done,
      pattern_done => done
    );

  -- Output assignments
  pattern_done <= done;
  abandon      <= abandon_sig;
  LW_dbg       <= LW_sig;
  HW_dbg       <= HW_sig;

end architecture;
