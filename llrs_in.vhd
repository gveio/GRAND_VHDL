library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.config_pkg.all;

entity llrs_in is
  generic (
    n_max : integer := 128;
    B     : integer := 6
  );
  port (clk, rst  : in  std_logic;
        n         : in  integer range 1 to n_max;
        llr_en    : in  std_logic;
        LLR_in    : in  std_logic_vector(n_max * B - 1 downto 0);       -- Each LLR (B-1 downto 0)
        LLR_mag   : out std_logic_vector(n_max * (B - 1) - 1 downto 0); -- Magnitude bits (B-2 downto 0)
        y_hard    : out std_logic_vector(n_max - 1 downto 0);
        load_done : out std_logic
       );
end entity;

architecture arch of llrs_in is
begin
  process (clk, rst)
  begin
    if (rst = '1') then
      load_done <= '0';
      LLR_mag <= (others => '0');
      y_hard <= (others => '0');
    elsif rising_edge(clk) then
      load_done <= '0';
      if llr_en = '1' then
        for i in 0 to n_max - 1 loop
          if i < n then
            LLR_mag((i + 1) * (B - 1) - 1 downto i * (B - 1)) <= LLR_in(i * B + (B - 2) downto i * B);
            y_hard(i) <= LLR_in(i * B + (B - 1)); -- sign bit (MSB) of each LLR
          end if;
        end loop;
        load_done <= '1';
      end if;
    end if;
  end process;
end architecture;
