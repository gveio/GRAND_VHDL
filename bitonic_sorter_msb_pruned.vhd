library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use work.config_pkg.all;
-- PIPELINED IN LOGN;
-- SORTER USING MSB-ONLY WITH TIEBREAK IN LAST STAGES USING LSBs COMPARISON 
-- AND PRUNING COMPARISONS OUTSIDE LW_MAX IN LAST 3 CAE STEPS;

entity bitonic_sorter_msb_pruned is
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

architecture pipeline_stage of bitonic_sorter_msb_pruned is

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

  type mag_array   is array (0 to n_max - 1) of unsigned(MSB_NUM - 1 downto 0);
  type index_array is array (0 to n_max - 1) of unsigned(WIDTH_INDICES - 1 downto 0);
  type lsb_array   is array (0 to n_max - 1) of unsigned(LSB_NUM - 1 downto 0);

  type mag_stage_array   is array (0 to LOGN_MAX) of mag_array;
  type index_stage_array is array (0 to LOGN_MAX) of index_array;
  type lsb_stage_array   is array (0 to LOGN_MAX) of lsb_array;

  signal mag_stages  : mag_stage_array;
  signal idx_stages  : index_stage_array;
  signal lsb_stages  : lsb_stage_array;
  signal stage_valid : std_logic_vector(LOGN_MAX downto 0) := (others => '0');
  signal done_sort_r : std_logic := '0';
  signal n_r         : integer range 0 to n_max := 0;
  signal load_en     : std_logic := '0';
  signal sort_en_d   : std_logic := '0';

begin

  done_sort <= done_sort_r;

  --------------------------------------------------------------------------
  -- runtime configuration
  --------------------------------------------------------------------------
  process(clk, rst)
  begin
    if rst = '1' then
      n_r <= 0;
    elsif rising_edge(clk) then
      if sort_en = '1' then
        n_r <= n;
      end if;
    end if;
  end process;

  process(clk, rst)
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
  process(clk, rst)
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
  process(clk, rst)
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
  gen_stages : for s in 0 to LOGN_MAX - 2 generate
  constant TIE_STAGE : boolean := (s >= TIE_START);
begin
    process(clk, rst)
      variable dist         : integer;
      variable seq_len      : integer;
      variable partner      : integer range 0 to n_max - 1;
      variable dir_asc      : boolean;
      variable mag_a, mag_b : unsigned(MSB_NUM - 1 downto 0);
      variable idx_a, idx_b : unsigned(WIDTH_INDICES - 1 downto 0);
      variable lsb_a, lsb_b : unsigned(LSB_NUM - 1 downto 0);
      variable tmp_mag      : mag_array;
      variable tmp_idx      : index_array;
      variable tmp_lsb      : lsb_array;
      variable do_swap      : boolean;
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
  
 final_stage_pruned : process(clk, rst)
  variable dist         : integer;
  variable partner      : integer range 0 to n_max - 1;
  variable dir_asc      : boolean;
  variable mag_a, mag_b : unsigned(MSB_NUM - 1 downto 0);
  variable idx_a, idx_b : unsigned(WIDTH_INDICES - 1 downto 0);
  variable lsb_a, lsb_b : unsigned(LSB_NUM - 1 downto 0);
  variable tmp_mag      : mag_array;
  variable tmp_idx      : index_array;
  variable tmp_lsb      : lsb_array;
  variable do_swap      : boolean;
  variable key_a, key_b : unsigned(MSB_NUM + LSB_NUM - 1 downto 0);
begin
  if rst = '1' then
    for i in 0 to n_max - 1 loop
      mag_stages(LOGN_MAX)(i) <= (others => '0');
      idx_stages(LOGN_MAX)(i) <= (others => '0');
      lsb_stages(LOGN_MAX)(i) <= (others => '0');
    end loop;

  elsif rising_edge(clk) then
    for i in 0 to n_max - 1 loop
      tmp_mag(i) := mag_stages(LOGN_MAX - 1)(i);
      tmp_idx(i) := idx_stages(LOGN_MAX - 1)(i);
      tmp_lsb(i) := lsb_stages(LOGN_MAX - 1)(i);
    end loop;

    if stage_valid(LOGN_MAX - 1) = '1' then

      ----------------------------------------------------------------------
      -- dist = 128
      ----------------------------------------------------------------------
      dist := 128;
      for i in 0 to n_max - 1 loop
        partner := to_integer(unsigned(to_unsigned(i, WIDTH_INDICES) xor to_unsigned(dist, WIDTH_INDICES)));
        dir_asc := true;

        if (unsigned(to_unsigned(i, WIDTH_INDICES) and to_unsigned(dist, WIDTH_INDICES)) = 0) then
          mag_a := tmp_mag(i);
          mag_b := tmp_mag(partner);
          idx_a := tmp_idx(i);
          idx_b := tmp_idx(partner);
          lsb_a := tmp_lsb(i);
          lsb_b := tmp_lsb(partner);

          key_a := mag_a & lsb_a;
		 key_b := mag_b & lsb_b;
		 do_swap := (key_a > key_b);

          if do_swap then
            tmp_mag(i)       := mag_b;
            tmp_mag(partner) := mag_a;
            tmp_idx(i)       := idx_b;
            tmp_idx(partner) := idx_a;
            tmp_lsb(i)       := lsb_b;
            tmp_lsb(partner) := lsb_a;
          end if;
        end if;
      end loop;

      ----------------------------------------------------------------------
      -- dist = 64
      ----------------------------------------------------------------------
      dist := 64;
      for i in 0 to n_max - 1 loop
        partner := to_integer(unsigned(to_unsigned(i, WIDTH_INDICES) xor to_unsigned(dist, WIDTH_INDICES)));
        dir_asc := true;

        if (unsigned(to_unsigned(i, WIDTH_INDICES) and to_unsigned(dist, WIDTH_INDICES)) = 0) then
          mag_a := tmp_mag(i);
          mag_b := tmp_mag(partner);
          idx_a := tmp_idx(i);
          idx_b := tmp_idx(partner);
          lsb_a := tmp_lsb(i);
          lsb_b := tmp_lsb(partner);

          key_a := mag_a & lsb_a;
		 key_b := mag_b & lsb_b;
		 do_swap := (key_a > key_b);

          if do_swap then
            tmp_mag(i)       := mag_b;
            tmp_mag(partner) := mag_a;
            tmp_idx(i)       := idx_b;
            tmp_idx(partner) := idx_a;
            tmp_lsb(i)       := lsb_b;
            tmp_lsb(partner) := lsb_a;
          end if;
        end if;
      end loop;

      ----------------------------------------------------------------------
      -- dist = 32
      ----------------------------------------------------------------------
      dist := 32;
      for i in 0 to n_max - 1 loop
        partner := to_integer(unsigned(to_unsigned(i, WIDTH_INDICES) xor to_unsigned(dist, WIDTH_INDICES)));
        dir_asc := true;

        if (unsigned(to_unsigned(i, WIDTH_INDICES) and to_unsigned(dist, WIDTH_INDICES)) = 0) then
          mag_a := tmp_mag(i);
          mag_b := tmp_mag(partner);
          idx_a := tmp_idx(i);
          idx_b := tmp_idx(partner);
          lsb_a := tmp_lsb(i);
          lsb_b := tmp_lsb(partner);

          key_a := mag_a & lsb_a;
		 key_b := mag_b & lsb_b;
		 do_swap := (key_a > key_b);

          if do_swap then
            tmp_mag(i)       := mag_b;
            tmp_mag(partner) := mag_a;
            tmp_idx(i)       := idx_b;
            tmp_idx(partner) := idx_a;
            tmp_lsb(i)       := lsb_b;
            tmp_lsb(partner) := lsb_a;
          end if;
        end if;
      end loop;

      ----------------------------------------------------------------------
      -- dist = 16
      ----------------------------------------------------------------------
      dist := 16;
      for i in 0 to n_max - 1 loop
        partner := to_integer(unsigned(to_unsigned(i, WIDTH_INDICES) xor to_unsigned(dist, WIDTH_INDICES)));
        dir_asc := true;

        if (unsigned(to_unsigned(i, WIDTH_INDICES) and to_unsigned(dist, WIDTH_INDICES)) = 0) then
          mag_a := tmp_mag(i);
          mag_b := tmp_mag(partner);
          idx_a := tmp_idx(i);
          idx_b := tmp_idx(partner);
          lsb_a := tmp_lsb(i);
          lsb_b := tmp_lsb(partner);

          key_a := mag_a & lsb_a;
	     key_b := mag_b & lsb_b;
		 do_swap := (key_a > key_b);

          if do_swap then
            tmp_mag(i)       := mag_b;
            tmp_mag(partner) := mag_a;
            tmp_idx(i)       := idx_b;
            tmp_idx(partner) := idx_a;
            tmp_lsb(i)       := lsb_b;
            tmp_lsb(partner) := lsb_a;
          end if;
        end if;
      end loop;

      ----------------------------------------------------------------------
      -- dist = 8
      ----------------------------------------------------------------------
      dist := 8;
      for i in 0 to n_max - 1 loop
        partner := to_integer(unsigned(to_unsigned(i, WIDTH_INDICES) xor to_unsigned(dist, WIDTH_INDICES)));
        dir_asc := true;

        if (unsigned(to_unsigned(i, WIDTH_INDICES) and to_unsigned(dist, WIDTH_INDICES)) = 0) then
          mag_a := tmp_mag(i);
          mag_b := tmp_mag(partner);
          idx_a := tmp_idx(i);
          idx_b := tmp_idx(partner);
          lsb_a := tmp_lsb(i);
          lsb_b := tmp_lsb(partner);

          key_a := mag_a & lsb_a;
		 key_b := mag_b & lsb_b;
		 do_swap := (key_a > key_b);

          if do_swap then
            tmp_mag(i)       := mag_b;
            tmp_mag(partner) := mag_a;
            tmp_idx(i)       := idx_b;
            tmp_idx(partner) := idx_a;
            tmp_lsb(i)       := lsb_b;
            tmp_lsb(partner) := lsb_a;
          end if;
        end if;
      end loop;

      ----------------------------------------------------------------------
      -- dist = 4  (PRUNED OUTSIDE LW_MAX)
      ----------------------------------------------------------------------
      dist := 4;
      for i in 0 to n_max - 1 loop
        partner := to_integer(unsigned(to_unsigned(i, WIDTH_INDICES) xor to_unsigned(dist, WIDTH_INDICES)));
        dir_asc := true;

        if (unsigned(to_unsigned(i, WIDTH_INDICES) and to_unsigned(dist, WIDTH_INDICES)) = 0) then
          if not ((i >= LW_MAX) and (partner >= LW_MAX)) then
            mag_a := tmp_mag(i);
            mag_b := tmp_mag(partner);
            idx_a := tmp_idx(i);
            idx_b := tmp_idx(partner);
            lsb_a := tmp_lsb(i);
            lsb_b := tmp_lsb(partner);

            key_a := mag_a & lsb_a;
		   key_b := mag_b & lsb_b;
		   do_swap := (key_a > key_b);

            if do_swap then
              tmp_mag(i)       := mag_b;
              tmp_mag(partner) := mag_a;
              tmp_idx(i)       := idx_b;
              tmp_idx(partner) := idx_a;
              tmp_lsb(i)       := lsb_b;
              tmp_lsb(partner) := lsb_a;
            end if;
          end if;
        end if;
      end loop;

      ----------------------------------------------------------------------
      -- dist = 2  (PRUNED OUTSIDE LW_MAX)
      ----------------------------------------------------------------------
      dist := 2;
      for i in 0 to n_max - 1 loop
        partner := to_integer(unsigned(to_unsigned(i, WIDTH_INDICES) xor to_unsigned(dist, WIDTH_INDICES)));
        dir_asc := true;

        if (unsigned(to_unsigned(i, WIDTH_INDICES) and to_unsigned(dist, WIDTH_INDICES)) = 0) then
          if not ((i >= LW_MAX) and (partner >= LW_MAX)) then
            mag_a := tmp_mag(i);
            mag_b := tmp_mag(partner);
            idx_a := tmp_idx(i);
            idx_b := tmp_idx(partner);
            lsb_a := tmp_lsb(i);
            lsb_b := tmp_lsb(partner);

            key_a := mag_a & lsb_a;
		   key_b := mag_b & lsb_b;
		   do_swap := (key_a > key_b);

            if do_swap then
              tmp_mag(i)       := mag_b;
              tmp_mag(partner) := mag_a;
              tmp_idx(i)       := idx_b;
              tmp_idx(partner) := idx_a;
              tmp_lsb(i)       := lsb_b;
              tmp_lsb(partner) := lsb_a;
            end if;
          end if;
        end if;
      end loop;

      ----------------------------------------------------------------------
      -- dist = 1  (PRUNED OUTSIDE LW_MAX)
      ----------------------------------------------------------------------
      dist := 1;
      for i in 0 to n_max - 1 loop
        partner := to_integer(unsigned(to_unsigned(i, WIDTH_INDICES) xor to_unsigned(dist, WIDTH_INDICES)));
        dir_asc := true;

        if (unsigned(to_unsigned(i, WIDTH_INDICES) and to_unsigned(dist, WIDTH_INDICES)) = 0) then
          if not ((i >= LW_MAX) and (partner >= LW_MAX)) then
            mag_a := tmp_mag(i);
            mag_b := tmp_mag(partner);
            idx_a := tmp_idx(i);
            idx_b := tmp_idx(partner);
            lsb_a := tmp_lsb(i);
            lsb_b := tmp_lsb(partner);

		   key_a := mag_a & lsb_a;
		   key_b := mag_b & lsb_b;
		   do_swap := (key_a > key_b);

            if do_swap then
              tmp_mag(i)       := mag_b;
              tmp_mag(partner) := mag_a;
              tmp_idx(i)       := idx_b;
              tmp_idx(partner) := idx_a;
              tmp_lsb(i)       := lsb_b;
              tmp_lsb(partner) := lsb_a;
            end if;
          end if;
        end if;
      end loop;

      for j in 0 to n_max - 1 loop
        mag_stages(LOGN_MAX)(j) <= tmp_mag(j);
        idx_stages(LOGN_MAX)(j) <= tmp_idx(j);
        lsb_stages(LOGN_MAX)(j) <= tmp_lsb(j);
      end loop;
    end if;
  end if;
end process;

-------------------------------------------------------------------------
  -- output indices
  --------------------------------------------------------------------------
  process(clk, rst)
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