library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use work.config_pkg.all;

entity landslide_unit is
  generic (
    LW_MAX : integer := 104;
    HW_MAX : integer := 13
  );
  port (
    clk, rst         : in  std_logic;
    gen_en           : in  std_logic;
    LW               : in  integer range 1 to LW_MAX;
    HW               : in  integer range 1 to HW_MAX;
    pattern          : out std_logic_vector(HW_MAX * WIDTH_PATTERN - 1 downto 0);
    per_pattern_done : out std_logic;
    pattern_done     : out std_logic
  );
end entity;

architecture arch of landslide_unit is

  -- Registered configuration
  signal LW_reg : integer range 1 to LW_MAX := 1;
  signal HW_reg : integer range 1 to HW_MAX := 1;

  -- Precomputed initial residual for current LW/HW
  signal init_residual : unsigned(WIDTH_PATTERN - 1 downto 0);

  -- Registered (current) values
  signal core_reg             : array_t                                               := (others => (others => '0'));
  signal residual_reg         : array_t                                               := (others => (others => '0'));
  signal pattern_reg          : pattern_array_t                                       := (others => (others => '0'));
  signal pattern_vec_reg      : std_logic_vector(HW_MAX * WIDTH_PATTERN - 1 downto 0) := (others => '0');
  signal pattern_done_reg     : std_logic                                             := '0';
  signal per_pattern_done_reg : std_logic                                             := '0';
  -- Control
  signal cont     : std_logic := '0'; -- '1' = running for current LW/HW
  signal new_pair : std_logic := '0'; -- detect new LW/HW pair on inputs

  -- Next-state signals
  signal core_next         : array_t                                               := (others => (others => '0'));
  signal residual_next     : array_t                                               := (others => (others => '0'));
  signal pattern_next      : pattern_array_t                                       := (others => (others => '0'));
  signal pattern_vec_next  : std_logic_vector(HW_MAX * WIDTH_PATTERN - 1 downto 0) := (others => '0');
  signal pattern_done_next : std_logic                                             := '0';

begin
  -- initial residual: LW - sum_{i=1..HW} i
  -- Initial residual from current inputs (used only when we latch a new pair)
  init_residual <= to_unsigned(LW, WIDTH_PATTERN) - to_unsigned(HW * (HW + 1) / 2, WIDTH_PATTERN);

  -- new pair when external LW/HW != latched LW_reg/HW_reg
  new_pair <= '1' when (LW /= LW_reg) or (HW /= HW_reg) else
              '0';

  -- COMBINATIONAL
  -- compute next state core/residual/pattern/done/continue values
  -- prevents computing new values after done
  comb: process (core_reg, residual_reg, pattern_reg, pattern_vec_reg, pattern_done_reg, HW_reg, new_pair)
    variable base_HW   : array_t;
    variable drop      : array_t;
    variable drop_comp : drop_t;
    variable drop_idx  : drop_t;
    variable sel       : drop_t;

    variable residual_sum : unsigned(WIDTH_PATTERN - 1 downto 0);
    variable core_sum     : unsigned(WIDTH_PATTERN - 1 downto 0);
    variable crust        : unsigned(WIDTH_PATTERN - 1 downto 0);
    variable core_var     : array_t;

    variable k           : unsigned(WIDTH_PATTERN - 1 downto 0);
    variable or_red      : std_logic;
    variable pattern_var : std_logic_vector(WIDTH_PATTERN - 1 downto 0);
  begin
    -- Defaults: hold state
    core_next <= core_reg;
    residual_next <= residual_reg;
    pattern_next <= pattern_reg;
    pattern_vec_next <= pattern_vec_reg;
    pattern_done_next <= pattern_done_reg;

    -- If not new pair or already done, do nothing (hold registers)
    if (pattern_done_reg = '1') and (new_pair = '0') then
      core_next <= core_reg;
      residual_next <= residual_reg;
      pattern_next <= pattern_reg;
      pattern_vec_next <= pattern_vec_reg;
      pattern_done_next <= pattern_done_reg;

      -- normal landslide computation
    else
      -- Base HW sequence and pattern build
      base_HW := (others => (others => '0'));
      residual_sum := (others => '0');
      pattern_var := (others => '0');
      pattern_vec_next <= (others => '0');

      for i in 1 to HW_MAX loop
        if i <= HW_reg then
          base_HW(i) := to_unsigned(i, WIDTH_PATTERN);
          pattern_var := std_logic_vector(base_HW(i) + residual_reg(i));
          pattern_next(i) <= pattern_var;
          pattern_vec_next((i * WIDTH_PATTERN - 1) downto ((i - 1) * WIDTH_PATTERN)) <= pattern_var; -- pack pattern
          residual_sum := residual_sum + residual_reg(i);
        else
          base_HW(i) := (others => '0');
          pattern_next(i) <= (others => '0');
        end if;
      end loop;

      -- Drop computation
      drop := (others => (others => '0'));
      drop_comp := (others => '0');
      for i in 1 to HW_MAX loop
        if i <= HW_reg then
          drop(i) := residual_reg(HW_reg) - residual_reg(i);
          if unsigned(drop(i)(WIDTH_PATTERN - 1 downto 1)) /= 0 then
            drop_comp(i) := '1'; -- real drop > 1
          else
            drop_comp(i) := '0';
          end if;
        else
          drop(i) := (others => '0');
          drop_comp(i) := '0';
        end if;
      end loop;

      or_red := '0';
      for i in 1 to HW_MAX loop
        if i <= HW_reg then
          or_red := or_red or drop_comp(i);
        end if;
      end loop;

      if or_red = '0' then -- done = 1 (nor-reduce), no more partitions for given LW,HW
        pattern_done_next <= '1';
      else
        pattern_done_next <= '0';
      end if;

      -- Drop index
      drop_idx := (others => '0');
      for i in 1 to HW_MAX - 1 loop
        if i <= HW_reg - 1 then
          drop_idx(i) := drop_comp(i) xor drop_comp(i + 1);
        else
          drop_idx(i) := '0';
        end if;
      end loop;
      drop_idx(HW_MAX) := '0';
      if HW_reg <= HW_MAX then
        drop_idx(HW_reg) := drop_comp(HW_reg);
      end if;

      -- last index k with drop > 1
      k := (others => '0');
      for i in 1 to HW_MAX loop
        if (i <= HW_reg) and (drop_idx(i) = '1') then
          k := residual_reg(i) + to_unsigned(1, WIDTH_PATTERN);
        end if;
      end loop;

      -- sel(i): where to write k (sliding column)
      sel := (others => '1'); -- preserve core_reg
      for i in 1 to HW_MAX loop
        if i <= HW_reg - 1 then
          sel(i) := drop_idx(i) xor drop_comp(i);
        elsif i = HW_reg then
          sel(i) := drop_comp(i);
        else
          sel(i) := '1'; -- outside HW: preserve core_reg
        end if;
      end loop;

      -- Next core values
      core_sum := (others => '0');
      core_var := core_reg;

      for i in 1 to HW_MAX loop
        if i <= HW_reg then
          if sel(i) = '0' then
            core_var(i) := k;
          else
            core_var(i) := core_reg(i);
          end if;
          core_sum := core_sum + core_var(i);
        else
          core_var(i) := (others => '0');
        end if;
      end loop;

      core_next <= core_var;

      -- Crust and next residual
      crust := residual_sum - core_sum; -- remaining residual blocks called the crust will be placed in the highest column again

      for i in 1 to HW_MAX loop
        if i < HW_reg then
          residual_next(i) <= core_var(i);
        elsif i = HW_reg then
          residual_next(i) <= core_var(i) + crust;
        else
          residual_next(i) <= (others => '0');
        end if;
      end loop;
    end if;
  end process;

  -- SEQUENTIAL 
  -- Writes next-state into registers
  -- Prevents loading new values after done
  -- MUX behavior for residual_reg
  seq: process (clk, rst)
  begin
    if rst = '1' then
      LW_reg <= 1;
      HW_reg <= 1;
      cont <= '0';
      core_reg <= (others => (others => '0'));
      residual_reg <= (others => (others => '0'));
      pattern_reg <= (others => (others => '0'));
      pattern_vec_reg <= (others => '0');
      pattern_done_reg <= '0';
      per_pattern_done_reg <= '0';

    elsif rising_edge(clk) then
      if gen_en = '1' then

        -- NEW LW/HW pair detected → (re)start Landslide
        if (cont = '0') or (new_pair = '1') then
          LW_reg <= LW;
          HW_reg <= HW;
          cont <= '1';
          pattern_done_reg <= '0';
          per_pattern_done_reg <= '0';
          core_reg <= (others => (others => '0'));
          --pattern_reg <= (others => (others => '0')); remove the zero pattern when new pair

          -- initial residual: only HW-th column gets LW - sum(1..HW)
          for i in 1 to HW_MAX loop
            if i = HW then
              residual_reg(i) <= init_residual;
            else
              residual_reg(i) <= (others => '0');
            end if;
          end loop;

          -- Normal Landslide iteration for current LW_reg/HW_reg
        elsif (cont = '1') and (pattern_done_reg = '0') then
          core_reg <= core_next;
          residual_reg <= residual_next;
          pattern_reg <= pattern_next;
          pattern_vec_reg <= pattern_vec_next;
          pattern_done_reg <= pattern_done_next;
          per_pattern_done_reg <= '1';
          -- if done asserted, cont will stay '1' but logic is frozen by comb

        elsif (cont = '1') and (pattern_done_reg = '1') then
          -- DONE: freeze residual to zero until new pair arrives
          residual_reg <= (others => (others => '0'));
          core_reg <= (others => (others => '0'));
          pattern_reg <= pattern_reg;
          pattern_vec_reg <= pattern_vec_reg;
          pattern_done_reg <= '1';
          per_pattern_done_reg <= '0';

          -- Done and no new LW/HW → hold everything
        else
          core_reg <= core_reg;
          residual_reg <= residual_reg;
          pattern_reg <= pattern_reg;
          pattern_vec_reg <= pattern_vec_reg;
          pattern_done_reg <= pattern_done_reg;
          cont <= cont;
          per_pattern_done_reg <= '0';
        end if;
      else
        -- gen_en = 0 → go idle, but keep outputs
        cont <= '0';
        pattern_done_reg <= '0';
        per_pattern_done_reg <= '0';
      end if;
    end if;
  end process;

  pattern          <= pattern_vec_reg; -- vector output ( for array pattern_reg and pattern patter_array )
  per_pattern_done <= per_pattern_done_reg;
  pattern_done     <= pattern_done_reg when (new_pair = '0' and cont = '1') else '0';

end architecture;
