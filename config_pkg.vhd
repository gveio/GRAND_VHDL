library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use ieee.math_real.all;

package config_pkg is

  constant n_max         : integer := 256;
  constant nk_max         : integer := 16;
  constant WIDTH_INDICES : integer := (integer(ceil(log2(real(n_max)))));
  constant LW_MAX        : integer := 104; -- maximum logistic weight 
  constant HW_MAX        : integer := 13;  -- maximum hamming weight
  constant WIDTH_PATTERN : integer := (integer(ceil(log2(real(LW_MAX)))));

  -- Types for Pattern Generator
  -- A single pattern element = index of least reliable bit (1..LW_MAX)
  -- Full pattern = list of HW_MAX indices
  type pattern_array_t is array (1 to HW_MAX) of std_logic_vector(WIDTH_PATTERN - 1 downto 0);
  -- Types for landslide registers
  type array_t is array (1 to HW_MAX) of unsigned(WIDTH_PATTERN - 1 downto 0);
  type drop_t is array (1 to HW_MAX) of std_logic;

  -- Types for Error Generator
  type index_array_t is array (1 to HW_MAX) of unsigned(WIDTH_INDICES - 1 downto 0);
end package;
