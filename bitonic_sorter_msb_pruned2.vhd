library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use ieee.math_real.all;
  use work.config_pkg.all;
  -- PIPELINED IN LOGN;
  -- SORTER USING MSB-ONLY WITH TIEBREAK IN LAST STAGES USING LSBs COMPARISON 
  -- AND PRUNING COMPARISONS OUTSIDE LW_MAX IN LAST 3 CAE STEPS;

entity bitonic_sorter_msb_pruned2 is
  generic (
    n_max  : integer := 256;
    B_mag  : integer := 5;
    LW_MAX : integer := 104
  );
  port (
    clk, rst       : in  std_logic;
    n              : in  integer range 1 to n_max;
    sort_en        : in  std_logic;
    LLR_mag        : in  std_logic_vector(n_max * B_mag - 1 downto 0);
    sorted_indices : out std_logic_vector(LW_MAX * WIDTH_INDICES - 1 downto 0);
    done_sort      : out std_logic
  );
end entity;

architecture pipeline_stage of bitonic_sorter_msb_pruned2 is

  function int_log2_ceil(x : integer) return integer is
  begin
    if x <= 1 then
      return 0;
    elsif x <= 2 then
      return 1;
    elsif x <= 4 then
      return 2;
    elsif x <= 8 then
      return 3;
    elsif x <= 16 then
      return 4;
    elsif x <= 32 then
      return 5;
    elsif x <= 64 then
      return 6;
    elsif x <= 128 then
      return 7;
    else
      return 8;
    end if;
  end function;

  constant LOGN_MAX  : integer := int_log2_ceil(n_max);
  constant MSB_NUM   : integer := 3;
  constant LSB_NUM   : integer := 2;
  constant TIE_START : integer := LOGN_MAX - 2;

  type mag_array is array (0 to n_max - 1) of unsigned(MSB_NUM - 1 downto 0);
  type index_array is array (0 to n_max - 1) of unsigned(WIDTH_INDICES - 1 downto 0);
  type lsb_array is array (0 to n_max - 1) of unsigned(LSB_NUM - 1 downto 0);

  type mag_stage_array is array (0 to LOGN_MAX) of mag_array;
  type index_stage_array is array (0 to LOGN_MAX) of index_array;
  type lsb_stage_array is array (0 to LOGN_MAX) of lsb_array;

  signal mag_stages  : mag_stage_array;
  signal idx_stages  : index_stage_array;
  signal lsb_stages  : lsb_stage_array;
  signal stage_valid : std_logic_vector(LOGN_MAX downto 0) := (others => '0');
  signal done_sort_r : std_logic                           := '0';
  signal n_r         : integer range 0 to n_max            := 0;
  signal load_en     : std_logic                           := '0';
  signal sort_en_d   : std_logic                           := '0';

  -- Final-stage structural signals
  signal fs_mag_0, fs_mag_1, fs_mag_2, fs_mag_3, fs_mag_4, fs_mag_5, fs_mag_6, fs_mag_7, fs_mag_8 : mag_array   := (others => (others => '0'));
  signal fs_idx_0, fs_idx_1, fs_idx_2, fs_idx_3, fs_idx_4, fs_idx_5, fs_idx_6, fs_idx_7, fs_idx_8 : index_array := (others => (others => '0'));
  signal fs_lsb_0, fs_lsb_1, fs_lsb_2, fs_lsb_3, fs_lsb_4, fs_lsb_5, fs_lsb_6, fs_lsb_7, fs_lsb_8 : lsb_array   := (others => (others => '0'));

begin

  done_sort <= done_sort_r;

  --------------------------------------------------------------------------
  -- runtime configuration

  --------------------------------------------------------------------------
  process (clk, rst)
  begin
    if rst = '1' then
      n_r <= 0;
    elsif rising_edge(clk) then
      if sort_en = '1' then
        n_r <= n;
      end if;
    end if;
  end process;

  process (clk, rst)
  begin
    if rst = '1' then
      sort_en_d <= '0';
    elsif rising_edge(clk) then
      sort_en_d <= sort_en;
    end if;
  end process;

  load_en <= sort_en_d;

  --------------------------------------------------------------------------
  -- stage 0 load: MSBs + indices + propagated LSBs

  --------------------------------------------------------------------------
  process (clk, rst)
  begin
    if rst = '1' then
      for i in 0 to n_max - 1 loop
        mag_stages(0)(i) <= (others => '0');
        idx_stages(0)(i) <= (others => '0');
        lsb_stages(0)(i) <= (others => '0');
      end loop;

    elsif rising_edge(clk) then
      if load_en = '1' then
        for i in 0 to n_max - 1 loop
          if i < n_r then
            mag_stages(0)(i) <= unsigned(LLR_mag((i + 1) * B_mag - 1 downto (i + 1) * B_mag - MSB_NUM));
            idx_stages(0)(i) <= to_unsigned(i, WIDTH_INDICES);
            lsb_stages(0)(i) <= unsigned(LLR_mag(i * B_mag + (LSB_NUM - 1) downto i * B_mag));
            --LSB_NUM = 1, 
            --lsb_stages(0)(i) <= unsigned(LLR_mag(i * B_mag + 1 downto i * B_mag + 1));
          else
            mag_stages(0)(i) <= (others => '1');
            idx_stages(0)(i) <= to_unsigned(i, WIDTH_INDICES);
            lsb_stages(0)(i) <= (others => '1');
          end if;
        end loop;
      end if;
    end if;
  end process;

  --------------------------------------------------------------------------
  -- valid token pipeline

  --------------------------------------------------------------------------
  process (clk, rst)
  begin
    if rst = '1' then
      stage_valid <= (others => '0');
      done_sort_r <= '0';

    elsif rising_edge(clk) then
      done_sort_r <= '0';
      stage_valid(0) <= load_en;

      for s in 1 to LOGN_MAX loop
        stage_valid(s) <= stage_valid(s - 1);
      end loop;

      if stage_valid(LOGN_MAX) = '1' then
        done_sort_r <= '1';
      end if;
    end if;
  end process;

  --------------------------------------------------------------------------
  -- propagate mag + idx + lsb
  --------------------------------------------------------------------------
  gen_stages: for s in 0 to LOGN_MAX - 2 generate
    constant TIE_STAGE : boolean := (s >= TIE_START);
  begin
    process (clk, rst)
      variable dist           : integer;
      variable seq_len        : integer;
      variable partner        : integer range 0 to n_max - 1;
      variable dir_asc        : boolean;
      variable mag_a, mag_b   : unsigned(MSB_NUM - 1 downto 0);
      variable idx_a, idx_b   : unsigned(WIDTH_INDICES - 1 downto 0);
      variable lsb_a, lsb_b   : unsigned(LSB_NUM - 1 downto 0);
      variable tmp_mag        : mag_array;
      variable tmp_idx        : index_array;
      variable tmp_lsb        : lsb_array;
      variable do_swap        : boolean;
      variable full_a, full_b : unsigned(MSB_NUM + LSB_NUM - 1 downto 0);
    begin
      if rst = '1' then
        for i in 0 to n_max - 1 loop
          mag_stages(s + 1)(i) <= (others => '0');
          idx_stages(s + 1)(i) <= (others => '0');
          lsb_stages(s + 1)(i) <= (others => '0');
        end loop;

      elsif rising_edge(clk) then
        for i in 0 to n_max - 1 loop
          tmp_mag(i) := mag_stages(s)(i);
          tmp_idx(i) := idx_stages(s)(i);
          tmp_lsb(i) := lsb_stages(s)(i);
        end loop;

        if stage_valid(s) = '1' then
          seq_len := 2 ** (s + 1);

          for k in 0 to s loop
            dist := 2 ** (s - k);

            for i in 0 to n_max - 1 loop
              partner := to_integer(unsigned(to_unsigned(i, WIDTH_INDICES) xor to_unsigned(dist, WIDTH_INDICES)));
              dir_asc := (i mod (2 * seq_len)) < seq_len;

              if (unsigned(to_unsigned(i, WIDTH_INDICES) and to_unsigned(dist, WIDTH_INDICES)) = 0) then

                mag_a := tmp_mag(i);
                mag_b := tmp_mag(partner);
                idx_a := tmp_idx(i);
                idx_b := tmp_idx(partner);
                lsb_a := tmp_lsb(i);
                lsb_b := tmp_lsb(partner);

                if TIE_STAGE then
                  full_a := mag_a & lsb_a;
                  full_b := mag_b & lsb_b;

                  if dir_asc then
                    do_swap := (full_a > full_b);
                  else
                    do_swap := (full_a < full_b);
                  end if;
                else
                  if dir_asc then
                    do_swap := (mag_a > mag_b);
                  else
                    do_swap := (mag_a < mag_b);
                  end if;
                end if;

                if do_swap then
                  tmp_mag(i) := mag_b;
                  tmp_mag(partner) := mag_a;
                  tmp_idx(i) := idx_b;
                  tmp_idx(partner) := idx_a;
                  tmp_lsb(i) := lsb_b;
                  tmp_lsb(partner) := lsb_a;
                end if;
              end if;
            end loop;
          end loop;

          for j in 0 to n_max - 1 loop
            mag_stages(s + 1)(j) <= tmp_mag(j);
            idx_stages(s + 1)(j) <= tmp_idx(j);
            lsb_stages(s + 1)(j) <= tmp_lsb(j);
          end loop;
        end if;
      end if;
    end process;
  end generate;

  fs_mag_0 <= mag_stages(LOGN_MAX - 1);
  fs_idx_0 <= idx_stages(LOGN_MAX - 1);
  fs_lsb_0 <= lsb_stages(LOGN_MAX - 1);

final_stage_d128 : process(fs_mag_0, fs_idx_0, fs_lsb_0)
    variable tmp_mag      : mag_array;
    variable tmp_idx      : index_array;
    variable tmp_lsb      : lsb_array;
    variable mag_a, mag_b : unsigned(MSB_NUM - 1 downto 0);
    variable idx_a, idx_b : unsigned(WIDTH_INDICES - 1 downto 0);
    variable lsb_a, lsb_b : unsigned(LSB_NUM - 1 downto 0);
    variable key_a, key_b : unsigned(MSB_NUM + LSB_NUM - 1 downto 0);
  begin
    -- default pass-through
    for i in 0 to n_max - 1 loop
      tmp_mag(i) := fs_mag_0(i);
      tmp_idx(i) := fs_idx_0(i);
      tmp_lsb(i) := fs_lsb_0(i);
    end loop;

    -- kept pairs: (0,128) ... (127,255)
    for i in 0 to 127 loop
      mag_a := fs_mag_0(i);
      mag_b := fs_mag_0(i + 128);
      idx_a := fs_idx_0(i);
      idx_b := fs_idx_0(i + 128);
      lsb_a := fs_lsb_0(i);
      lsb_b := fs_lsb_0(i + 128);

      key_a := mag_a & lsb_a;
      key_b := mag_b & lsb_b;

      if key_a > key_b then
        tmp_mag(i) := mag_b;
        tmp_mag(i + 128) := mag_a;
        tmp_idx(i) := idx_b;
        tmp_idx(i + 128) := idx_a;
        tmp_lsb(i) := lsb_b;
        tmp_lsb(i + 128) := lsb_a;
      end if;
    end loop;

    for i in 0 to n_max - 1 loop
      fs_mag_1(i) <= tmp_mag(i);
      fs_idx_1(i) <= tmp_idx(i);
      fs_lsb_1(i) <= tmp_lsb(i);
    end loop;
  end process;

final_stage_d64 : process(fs_mag_1, fs_idx_1, fs_lsb_1)
    variable tmp_mag      : mag_array;
    variable tmp_idx      : index_array;
    variable tmp_lsb      : lsb_array;
    variable mag_a, mag_b : unsigned(MSB_NUM - 1 downto 0);
    variable idx_a, idx_b : unsigned(WIDTH_INDICES - 1 downto 0);
    variable lsb_a, lsb_b : unsigned(LSB_NUM - 1 downto 0);
    variable key_a, key_b : unsigned(MSB_NUM + LSB_NUM - 1 downto 0);
  begin
    for i in 0 to n_max - 1 loop
      tmp_mag(i) := fs_mag_1(i);
      tmp_idx(i) := fs_idx_1(i);
      tmp_lsb(i) := fs_lsb_1(i);
    end loop;

    -- kept pairs: (0,64) ... (63,127)
    for i in 0 to 63 loop
      mag_a := fs_mag_1(i);
      mag_b := fs_mag_1(i + 64);
      idx_a := fs_idx_1(i);
      idx_b := fs_idx_1(i + 64);
      lsb_a := fs_lsb_1(i);
      lsb_b := fs_lsb_1(i + 64);

      key_a := mag_a & lsb_a;
      key_b := mag_b & lsb_b;

      if key_a > key_b then
        tmp_mag(i) := mag_b;
        tmp_mag(i + 64) := mag_a;
        tmp_idx(i) := idx_b;
        tmp_idx(i + 64) := idx_a;
        tmp_lsb(i) := lsb_b;
        tmp_lsb(i + 64) := lsb_a;
      end if;
    end loop;

    for i in 0 to n_max - 1 loop
      fs_mag_2(i) <= tmp_mag(i);
      fs_idx_2(i) <= tmp_idx(i);
      fs_lsb_2(i) <= tmp_lsb(i);
    end loop;
  end process;

final_stage_d32 : process(fs_mag_2, fs_idx_2, fs_lsb_2)
    variable tmp_mag      : mag_array;
    variable tmp_idx      : index_array;
    variable tmp_lsb      : lsb_array;
    variable mag_a, mag_b : unsigned(MSB_NUM - 1 downto 0);
    variable idx_a, idx_b : unsigned(WIDTH_INDICES - 1 downto 0);
    variable lsb_a, lsb_b : unsigned(LSB_NUM - 1 downto 0);
    variable key_a, key_b : unsigned(MSB_NUM + LSB_NUM - 1 downto 0);
  begin
    for i in 0 to n_max - 1 loop
      tmp_mag(i) := fs_mag_2(i);
      tmp_idx(i) := fs_idx_2(i);
      tmp_lsb(i) := fs_lsb_2(i);
    end loop;

    -- kept group 0: (0,32) ... (31,63)
    for i in 0 to 31 loop
      mag_a := fs_mag_2(i);
      mag_b := fs_mag_2(i + 32);
      idx_a := fs_idx_2(i);
      idx_b := fs_idx_2(i + 32);
      lsb_a := fs_lsb_2(i);
      lsb_b := fs_lsb_2(i + 32);

      key_a := mag_a & lsb_a;
      key_b := mag_b & lsb_b;

      if key_a > key_b then
        tmp_mag(i) := mag_b;
        tmp_mag(i + 32) := mag_a;
        tmp_idx(i) := idx_b;
        tmp_idx(i + 32) := idx_a;
        tmp_lsb(i) := lsb_b;
        tmp_lsb(i + 32) := lsb_a;
      end if;
    end loop;

    -- kept group 1: (64,96) ... (95,127)
    for i in 64 to 95 loop
      mag_a := fs_mag_2(i);
      mag_b := fs_mag_2(i + 32);
      idx_a := fs_idx_2(i);
      idx_b := fs_idx_2(i + 32);
      lsb_a := fs_lsb_2(i);
      lsb_b := fs_lsb_2(i + 32);

      key_a := mag_a & lsb_a;
      key_b := mag_b & lsb_b;

      if key_a > key_b then
        tmp_mag(i) := mag_b;
        tmp_mag(i + 32) := mag_a;
        tmp_idx(i) := idx_b;
        tmp_idx(i + 32) := idx_a;
        tmp_lsb(i) := lsb_b;
        tmp_lsb(i + 32) := lsb_a;
      end if;
    end loop;

    for i in 0 to n_max - 1 loop
      fs_mag_3(i) <= tmp_mag(i);
      fs_idx_3(i) <= tmp_idx(i);
      fs_lsb_3(i) <= tmp_lsb(i);
    end loop;
  end process;

final_stage_d16 : process(fs_mag_3, fs_idx_3, fs_lsb_3)
    variable tmp_mag      : mag_array;
    variable tmp_idx      : index_array;
    variable tmp_lsb      : lsb_array;
    variable mag_a, mag_b : unsigned(MSB_NUM - 1 downto 0);
    variable idx_a, idx_b : unsigned(WIDTH_INDICES - 1 downto 0);
    variable lsb_a, lsb_b : unsigned(LSB_NUM - 1 downto 0);
    variable key_a, key_b : unsigned(MSB_NUM + LSB_NUM - 1 downto 0);
  begin
    for i in 0 to n_max - 1 loop
      tmp_mag(i) := fs_mag_3(i);
      tmp_idx(i) := fs_idx_3(i);
      tmp_lsb(i) := fs_lsb_3(i);
    end loop;

    -- groups: 0..15, 32..47, 64..79, 96..111
    for i in 0 to 15 loop
      mag_a := fs_mag_3(i);
      mag_b := fs_mag_3(i + 16);
      idx_a := fs_idx_3(i);
      idx_b := fs_idx_3(i + 16);
      lsb_a := fs_lsb_3(i);
      lsb_b := fs_lsb_3(i + 16);
      key_a := mag_a & lsb_a;
      key_b := mag_b & lsb_b;
      if key_a > key_b then
        tmp_mag(i) := mag_b;
        tmp_mag(i + 16) := mag_a;
        tmp_idx(i) := idx_b;
        tmp_idx(i + 16) := idx_a;
        tmp_lsb(i) := lsb_b;
        tmp_lsb(i + 16) := lsb_a;
      end if;
    end loop;

    for i in 32 to 47 loop
      mag_a := fs_mag_3(i);
      mag_b := fs_mag_3(i + 16);
      idx_a := fs_idx_3(i);
      idx_b := fs_idx_3(i + 16);
      lsb_a := fs_lsb_3(i);
      lsb_b := fs_lsb_3(i + 16);
      key_a := mag_a & lsb_a;
      key_b := mag_b & lsb_b;
      if key_a > key_b then
        tmp_mag(i) := mag_b;
        tmp_mag(i + 16) := mag_a;
        tmp_idx(i) := idx_b;
        tmp_idx(i + 16) := idx_a;
        tmp_lsb(i) := lsb_b;
        tmp_lsb(i + 16) := lsb_a;
      end if;
    end loop;

    for i in 64 to 79 loop
      mag_a := fs_mag_3(i);
      mag_b := fs_mag_3(i + 16);
      idx_a := fs_idx_3(i);
      idx_b := fs_idx_3(i + 16);
      lsb_a := fs_lsb_3(i);
      lsb_b := fs_lsb_3(i + 16);
      key_a := mag_a & lsb_a;
      key_b := mag_b & lsb_b;
      if key_a > key_b then
        tmp_mag(i) := mag_b;
        tmp_mag(i + 16) := mag_a;
        tmp_idx(i) := idx_b;
        tmp_idx(i + 16) := idx_a;
        tmp_lsb(i) := lsb_b;
        tmp_lsb(i + 16) := lsb_a;
      end if;
    end loop;

    for i in 96 to 111 loop
      mag_a := fs_mag_3(i);
      mag_b := fs_mag_3(i + 16);
      idx_a := fs_idx_3(i);
      idx_b := fs_idx_3(i + 16);
      lsb_a := fs_lsb_3(i);
      lsb_b := fs_lsb_3(i + 16);
      key_a := mag_a & lsb_a;
      key_b := mag_b & lsb_b;
      if key_a > key_b then
        tmp_mag(i) := mag_b;
        tmp_mag(i + 16) := mag_a;
        tmp_idx(i) := idx_b;
        tmp_idx(i + 16) := idx_a;
        tmp_lsb(i) := lsb_b;
        tmp_lsb(i + 16) := lsb_a;
      end if;
    end loop;

    for i in 0 to n_max - 1 loop
      fs_mag_4(i) <= tmp_mag(i);
      fs_idx_4(i) <= tmp_idx(i);
      fs_lsb_4(i) <= tmp_lsb(i);
    end loop;
  end process;

final_stage_d8 : process(fs_mag_4, fs_idx_4, fs_lsb_4)
    variable tmp_mag      : mag_array;
    variable tmp_idx      : index_array;
    variable tmp_lsb      : lsb_array;
    variable mag_a, mag_b : unsigned(MSB_NUM - 1 downto 0);
    variable idx_a, idx_b : unsigned(WIDTH_INDICES - 1 downto 0);
    variable lsb_a, lsb_b : unsigned(LSB_NUM - 1 downto 0);
    variable key_a, key_b : unsigned(MSB_NUM + LSB_NUM - 1 downto 0);
  begin
    for i in 0 to n_max - 1 loop
      tmp_mag(i) := fs_mag_4(i);
      tmp_idx(i) := fs_idx_4(i);
      tmp_lsb(i) := fs_lsb_4(i);
    end loop;

    -- kept groups: 0..7,16..23,32..39,48..55,64..71,80..87,96..103
    for i in 0 to 7 loop
      mag_a := fs_mag_4(i);
      mag_b := fs_mag_4(i + 8);
      idx_a := fs_idx_4(i);
      idx_b := fs_idx_4(i + 8);
      lsb_a := fs_lsb_4(i);
      lsb_b := fs_lsb_4(i + 8);
      key_a := mag_a & lsb_a;
      key_b := mag_b & lsb_b;
      if key_a > key_b then
        tmp_mag(i) := mag_b;
        tmp_mag(i + 8) := mag_a;
        tmp_idx(i) := idx_b;
        tmp_idx(i + 8) := idx_a;
        tmp_lsb(i) := lsb_b;
        tmp_lsb(i + 8) := lsb_a;
      end if;
    end loop;

    for i in 16 to 23 loop
      mag_a := fs_mag_4(i);
      mag_b := fs_mag_4(i + 8);
      idx_a := fs_idx_4(i);
      idx_b := fs_idx_4(i + 8);
      lsb_a := fs_lsb_4(i);
      lsb_b := fs_lsb_4(i + 8);
      key_a := mag_a & lsb_a;
      key_b := mag_b & lsb_b;
      if key_a > key_b then
        tmp_mag(i) := mag_b;
        tmp_mag(i + 8) := mag_a;
        tmp_idx(i) := idx_b;
        tmp_idx(i + 8) := idx_a;
        tmp_lsb(i) := lsb_b;
        tmp_lsb(i + 8) := lsb_a;
      end if;
    end loop;

    for i in 32 to 39 loop
      mag_a := fs_mag_4(i);
      mag_b := fs_mag_4(i + 8);
      idx_a := fs_idx_4(i);
      idx_b := fs_idx_4(i + 8);
      lsb_a := fs_lsb_4(i);
      lsb_b := fs_lsb_4(i + 8);
      key_a := mag_a & lsb_a;
      key_b := mag_b & lsb_b;
      if key_a > key_b then
        tmp_mag(i) := mag_b;
        tmp_mag(i + 8) := mag_a;
        tmp_idx(i) := idx_b;
        tmp_idx(i + 8) := idx_a;
        tmp_lsb(i) := lsb_b;
        tmp_lsb(i + 8) := lsb_a;
      end if;
    end loop;

    for i in 48 to 55 loop
      mag_a := fs_mag_4(i);
      mag_b := fs_mag_4(i + 8);
      idx_a := fs_idx_4(i);
      idx_b := fs_idx_4(i + 8);
      lsb_a := fs_lsb_4(i);
      lsb_b := fs_lsb_4(i + 8);
      key_a := mag_a & lsb_a;
      key_b := mag_b & lsb_b;
      if key_a > key_b then
        tmp_mag(i) := mag_b;
        tmp_mag(i + 8) := mag_a;
        tmp_idx(i) := idx_b;
        tmp_idx(i + 8) := idx_a;
        tmp_lsb(i) := lsb_b;
        tmp_lsb(i + 8) := lsb_a;
      end if;
    end loop;

    for i in 64 to 71 loop
      mag_a := fs_mag_4(i);
      mag_b := fs_mag_4(i + 8);
      idx_a := fs_idx_4(i);
      idx_b := fs_idx_4(i + 8);
      lsb_a := fs_lsb_4(i);
      lsb_b := fs_lsb_4(i + 8);
      key_a := mag_a & lsb_a;
      key_b := mag_b & lsb_b;
      if key_a > key_b then
        tmp_mag(i) := mag_b;
        tmp_mag(i + 8) := mag_a;
        tmp_idx(i) := idx_b;
        tmp_idx(i + 8) := idx_a;
        tmp_lsb(i) := lsb_b;
        tmp_lsb(i + 8) := lsb_a;
      end if;
    end loop;

    for i in 80 to 87 loop
      mag_a := fs_mag_4(i);
      mag_b := fs_mag_4(i + 8);
      idx_a := fs_idx_4(i);
      idx_b := fs_idx_4(i + 8);
      lsb_a := fs_lsb_4(i);
      lsb_b := fs_lsb_4(i + 8);
      key_a := mag_a & lsb_a;
      key_b := mag_b & lsb_b;
      if key_a > key_b then
        tmp_mag(i) := mag_b;
        tmp_mag(i + 8) := mag_a;
        tmp_idx(i) := idx_b;
        tmp_idx(i + 8) := idx_a;
        tmp_lsb(i) := lsb_b;
        tmp_lsb(i + 8) := lsb_a;
      end if;
    end loop;

    for i in 96 to 103 loop
      mag_a := fs_mag_4(i);
      mag_b := fs_mag_4(i + 8);
      idx_a := fs_idx_4(i);
      idx_b := fs_idx_4(i + 8);
      lsb_a := fs_lsb_4(i);
      lsb_b := fs_lsb_4(i + 8);
      key_a := mag_a & lsb_a;
      key_b := mag_b & lsb_b;
      if key_a > key_b then
        tmp_mag(i) := mag_b;
        tmp_mag(i + 8) := mag_a;
        tmp_idx(i) := idx_b;
        tmp_idx(i + 8) := idx_a;
        tmp_lsb(i) := lsb_b;
        tmp_lsb(i + 8) := lsb_a;
      end if;
    end loop;

    for i in 0 to n_max - 1 loop
      fs_mag_5(i) <= tmp_mag(i);
      fs_idx_5(i) <= tmp_idx(i);
      fs_lsb_5(i) <= tmp_lsb(i);
    end loop;
  end process;

final_stage_d4 : process(fs_mag_5, fs_idx_5, fs_lsb_5)
    variable tmp_mag      : mag_array;
    variable tmp_idx      : index_array;
    variable tmp_lsb      : lsb_array;
    variable mag_a, mag_b : unsigned(MSB_NUM - 1 downto 0);
    variable idx_a, idx_b : unsigned(WIDTH_INDICES - 1 downto 0);
    variable lsb_a, lsb_b : unsigned(LSB_NUM - 1 downto 0);
    variable key_a, key_b : unsigned(MSB_NUM + LSB_NUM - 1 downto 0);
    variable i0           : integer;
  begin
    for i in 0 to n_max - 1 loop
      tmp_mag(i) := fs_mag_5(i);
      tmp_idx(i) := fs_idx_5(i);
      tmp_lsb(i) := fs_lsb_5(i);
    end loop;

    for blk in 0 to 12 loop
      for off in 0 to 3 loop
        i0 := 8 * blk + off;
        mag_a := fs_mag_5(i0);
        mag_b := fs_mag_5(i0 + 4);
        idx_a := fs_idx_5(i0);
        idx_b := fs_idx_5(i0 + 4);
        lsb_a := fs_lsb_5(i0);
        lsb_b := fs_lsb_5(i0 + 4);
        key_a := mag_a & lsb_a;
        key_b := mag_b & lsb_b;
        if key_a > key_b then
          tmp_mag(i0) := mag_b;
          tmp_mag(i0 + 4) := mag_a;
          tmp_idx(i0) := idx_b;
          tmp_idx(i0 + 4) := idx_a;
          tmp_lsb(i0) := lsb_b;
          tmp_lsb(i0 + 4) := lsb_a;
        end if;
      end loop;
    end loop;

    for i in 0 to n_max - 1 loop
      fs_mag_6(i) <= tmp_mag(i);
      fs_idx_6(i) <= tmp_idx(i);
      fs_lsb_6(i) <= tmp_lsb(i);
    end loop;
  end process;

final_stage_d2 : process(fs_mag_6, fs_idx_6, fs_lsb_6)
    variable tmp_mag      : mag_array;
    variable tmp_idx      : index_array;
    variable tmp_lsb      : lsb_array;
    variable mag_a, mag_b : unsigned(MSB_NUM - 1 downto 0);
    variable idx_a, idx_b : unsigned(WIDTH_INDICES - 1 downto 0);
    variable lsb_a, lsb_b : unsigned(LSB_NUM - 1 downto 0);
    variable key_a, key_b : unsigned(MSB_NUM + LSB_NUM - 1 downto 0);
    variable i0           : integer;
  begin
    for i in 0 to n_max - 1 loop
      tmp_mag(i) := fs_mag_6(i);
      tmp_idx(i) := fs_idx_6(i);
      tmp_lsb(i) := fs_lsb_6(i);
    end loop;

    for blk in 0 to 25 loop
      for off in 0 to 1 loop
        i0 := 4 * blk + off;
        mag_a := fs_mag_6(i0);
        mag_b := fs_mag_6(i0 + 2);
        idx_a := fs_idx_6(i0);
        idx_b := fs_idx_6(i0 + 2);
        lsb_a := fs_lsb_6(i0);
        lsb_b := fs_lsb_6(i0 + 2);
        key_a := mag_a & lsb_a;
        key_b := mag_b & lsb_b;
        if key_a > key_b then
          tmp_mag(i0) := mag_b;
          tmp_mag(i0 + 2) := mag_a;
          tmp_idx(i0) := idx_b;
          tmp_idx(i0 + 2) := idx_a;
          tmp_lsb(i0) := lsb_b;
          tmp_lsb(i0 + 2) := lsb_a;
        end if;
      end loop;
    end loop;

    for i in 0 to n_max - 1 loop
      fs_mag_7(i) <= tmp_mag(i);
      fs_idx_7(i) <= tmp_idx(i);
      fs_lsb_7(i) <= tmp_lsb(i);
    end loop;
  end process;

final_stage_d1 : process(fs_mag_7, fs_idx_7, fs_lsb_7)
    variable tmp_mag      : mag_array;
    variable tmp_idx      : index_array;
    variable tmp_lsb      : lsb_array;
    variable mag_a, mag_b : unsigned(MSB_NUM - 1 downto 0);
    variable idx_a, idx_b : unsigned(WIDTH_INDICES - 1 downto 0);
    variable lsb_a, lsb_b : unsigned(LSB_NUM - 1 downto 0);
    variable key_a, key_b : unsigned(MSB_NUM + LSB_NUM - 1 downto 0);
  begin
    for i in 0 to n_max - 1 loop
      tmp_mag(i) := fs_mag_7(i);
      tmp_idx(i) := fs_idx_7(i);
      tmp_lsb(i) := fs_lsb_7(i);
    end loop;

    for i in 0 to 51 loop
      mag_a := fs_mag_7(2 * i);
      mag_b := fs_mag_7(2 * i + 1);
      idx_a := fs_idx_7(2 * i);
      idx_b := fs_idx_7(2 * i + 1);
      lsb_a := fs_lsb_7(2 * i);
      lsb_b := fs_lsb_7(2 * i + 1);
      key_a := mag_a & lsb_a;
      key_b := mag_b & lsb_b;
      if key_a > key_b then
        tmp_mag(2 * i) := mag_b;
        tmp_mag(2 * i + 1) := mag_a;
        tmp_idx(2 * i) := idx_b;
        tmp_idx(2 * i + 1) := idx_a;
        tmp_lsb(2 * i) := lsb_b;
        tmp_lsb(2 * i + 1) := lsb_a;
      end if;
    end loop;

    for i in 0 to n_max - 1 loop
      fs_mag_8(i) <= tmp_mag(i);
      fs_idx_8(i) <= tmp_idx(i);
      fs_lsb_8(i) <= tmp_lsb(i);
    end loop;
  end process;

  final_stage_output_reg: process (clk, rst)
  begin
    if rst = '1' then
      for i in 0 to n_max - 1 loop
        mag_stages(LOGN_MAX)(i) <= (others => '0');
        idx_stages(LOGN_MAX)(i) <= (others => '0');
        lsb_stages(LOGN_MAX)(i) <= (others => '0');
      end loop;

    elsif rising_edge(clk) then
      if stage_valid(LOGN_MAX - 1) = '1' then
        for i in 0 to n_max - 1 loop
          mag_stages(LOGN_MAX)(i) <= fs_mag_8(i);
          idx_stages(LOGN_MAX)(i) <= fs_idx_8(i);
          lsb_stages(LOGN_MAX)(i) <= fs_lsb_8(i);
        end loop;
      end if;
    end if;
  end process;
  -------------------------------------------------------------------------
  -- output indices

  --------------------------------------------------------------------------
  process (clk, rst)
  begin
    if rst = '1' then
      sorted_indices <= (others => '0');

    elsif rising_edge(clk) then
      if done_sort_r = '1' then
        for i in 0 to LW_MAX - 1 loop
          sorted_indices((i + 1) * WIDTH_INDICES - 1 downto i * WIDTH_INDICES) <=
            std_logic_vector(idx_stages(LOGN_MAX)(i));
        end loop;
      end if;
    end if;
  end process;

end architecture;
