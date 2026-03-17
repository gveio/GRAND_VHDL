library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.types_pkg.all;
  use work.config_pkg.all;

entity error_checker is
  generic (
    n_max : integer := 256;
    nk_max : integer := 16
  );
  port (clk, rst         : in  std_logic;
        n                : in  integer range 1 to n_max;
        nk                : in  integer range 1 to nk_max;
        H_matrix_in      : in  H_matrix_type;
        y_in             : in  std_logic_vector(n_max - 1 downto 0);
        start_memb_check : in  std_logic;
        syn_out          : out std_logic_vector(nk_max - 1 downto 0);
        memb_check_done  : out std_logic;
        valid_memb_check : out std_logic
       );
end entity;

architecture arch1 of error_checker is
  signal syndrome_r : std_logic_vector(nk_max - 1 downto 0) := (others => '0');
  signal done_r     : std_logic                                    := '0';
  signal valid_r    : std_logic                                    := '0';
begin
  syn_out          <= syndrome_r;
  memb_check_done  <= done_r;
  valid_memb_check <= valid_r;

  process (clk, rst)
    variable syndrome : std_logic_vector(nk_max - 1 downto 0);
    variable or_red   : std_logic;
  begin
    if (rst = '1') then
      syndrome_r <= (others => '0');
      valid_r <= '0';
      done_r <= '0';

    elsif rising_edge(clk) then
      done_r <= '0';
      valid_r <= '0';
      if start_memb_check = '1' then
        syndrome := (others => '0');
        or_red := '0';
        for i in 0 to (nk_max - 1) loop
          -- default zero for all rows
          syndrome(i) := '0';
          -- only compute syndrome rows that belong to the actual (n,k) code
          if i < (nk) then
            for j in 0 to (n_max - 1) loop
              -- only use valid codeword positions
              if j < n then
                syndrome(i) := syndrome(i) xor (H_matrix_in(i)(j) and y_in(n - 1 - j));
              end if;
            end loop;
            or_red := or_red or syndrome(i); -- Reduction OR to check if all bits are zero
          else
            syndrome(i) := '0';
          end if;
        end loop;

        syndrome_r <= syndrome;

        if or_red = '0' then
          valid_r <= '1';
        else
          valid_r <= '0';
        end if;
        done_r <= '1';
      end if;
    end if;
  end process;
end architecture;

