library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use ieee.math_real.all;
  use work.config_pkg.all;

entity error_generator is
  generic (
    n_max  : integer := 256;
    LW_MAX : integer := 104;
    HW_MAX : integer := 13
  );
  port (
    clk, rst       : in  std_logic;
    error_en       : in  std_logic; -- global enable for error generator
    pattern        : in  std_logic_vector(HW_MAX * WIDTH_PATTERN - 1 downto 0);
    sorted_indices : in  std_logic_vector(LW_MAX * WIDTH_INDICES - 1 downto 0);
    y_hard         : in  std_logic_vector(n_max - 1 downto 0);
    noise_vec      : out std_logic_vector(n_max - 1 downto 0);
    y_guessed      : out std_logic_vector(n_max - 1 downto 0);
    error_done     : out std_logic
  );
end entity;

-- Sorter finishes
-- Pattern generator begins producing pattern
-- When pattern is ready asserts per_pattern_done (= error_en)
-- Error generator uses pattern + sorted list to flip bits

architecture arch of error_generator is
begin
  process (clk, rst)
    variable patt_sel       : unsigned(WIDTH_PATTERN - 1 downto 0) := (others => '0');
    variable patt_sel_int   : integer range 0 to LW_MAX            := 0;
    variable high_index     : index_array_t                        := (others => (others => '0'));
    variable high_index_int : integer range 0 to n_max             := 0;
    variable noise_var      : std_logic_vector(n_max - 1 downto 0) := (others => '0');
  begin
    if rst = '1' then
      noise_vec <= (others => '0');
      y_guessed <= (others => '0');
      error_done <= '0';
    elsif rising_edge(clk) then
      error_done <= '0';
      if error_en = '1' then
        noise_var := (others => '0');
        for i in 1 to HW_MAX loop
          patt_sel := unsigned(pattern(i * WIDTH_PATTERN - 1 downto (i - 1) * WIDTH_PATTERN)); -- Slice pattern in pattern elements for selectors (13 copies of 104-to-1 MUXes)
          patt_sel_int := to_integer(patt_sel);
          if (patt_sel_int >= 1) and (patt_sel_int <= LW_MAX) then
            -- slice the corresponding WIDTH-bit index from sorted_indices
            high_index(i) := unsigned(sorted_indices(patt_sel_int * WIDTH_INDICES - 1 downto (patt_sel_int - 1) * WIDTH_INDICES)); -- array of selected indices from the sorter to set high
            high_index_int := to_integer(high_index(i)); -- convert that index to integer and set the noise bit
            noise_var(high_index_int) := '1'; -- binary decoder
          end if;
        end loop;
        noise_vec <= noise_var;
        y_guessed <= noise_var xor y_hard;
        error_done <= '1';
      end if;
    end if;
  end process;
end architecture;

