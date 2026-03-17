library ieee; 
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.config_pkg.all;

entity lw_hw_generation_unit is
  generic (
    LW_MAX : integer := 104;
    HW_MAX : integer := 13
  );
  port (
    clk, rst     : in  std_logic;
    gen_en       : in  std_logic;
    pattern_done : in  std_logic;
    LW           : out integer range 1 to LW_MAX;
    HW           : out integer range 1 to HW_MAX;
    abandon      : out std_logic
  );
end entity;

architecture arch of lw_hw_generation_unit is

  signal LW_reg     : integer range 1 to LW_MAX := 1;
  signal HW_reg     : integer range 1 to HW_MAX := 1;

begin

  process (clk, rst)
    variable sum_HW : integer := 0; 
  begin
    if rst = '1' then
      LW_reg     <= 1;
      HW_reg     <= 1;
      abandon    <= '0';

    elsif rising_edge(clk) then
      if gen_en = '1' then

        if pattern_done = '1' then

          -- Compute triangular number of the next HW value sum_HW = (HW+1)*(HW+2)/2
          sum_HW := (HW_reg + 1) * (HW_reg + 2) / 2; -- if sum(HW+1) <= LW then HW++, else LW++, HW=1

          if (sum_HW <= LW_reg) and (HW_reg < HW_MAX) then
            -- Same LW, increment HW
            HW_reg <= HW_reg + 1;
          else
            -- Cannot increase HW move to next LW
            HW_reg     <= 1;

            if LW_reg < LW_max then
              LW_reg  <= LW_reg + 1;
              abandon <= '0';
            else
              LW_reg  <= LW_max;
              abandon <= '1';
            end if;
          end if;
        end if;   
      end if;  
    end if;    
  end process;

  LW <= LW_reg;
  HW <= HW_reg;

end architecture;
