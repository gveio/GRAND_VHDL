library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use ieee.math_real.all;
  use work.config_pkg.all;

  -- PIPELINED IN LOGN(LOGN+1)/2;

entity bitonic_sorter_2 is
  generic (
    n_max  : integer := 128;
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

architecture pipeline_substage of bitonic_sorter_2 is

  function ceil_pow2(x : integer) return integer is
  begin
    if x <= 1 then
      return 1;
    elsif x <= 2 then
      return 2;
    elsif x <= 4 then
      return 4;
    elsif x <= 8 then
      return 8;
    elsif x <= 16 then
      return 16;
    elsif x <= 32 then
      return 32;
    elsif x <= 64 then
      return 64;
    elsif x <= 128 then
      return 128;
    else
      return 256;
    end if;
  end function;

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

  constant LOGN_MAX : integer := int_log2_ceil(n_max);
  constant STAGES   : integer := LOGN_MAX * (LOGN_MAX + 1) / 2;

  type mag_array is array (0 to n_max - 1) of unsigned(B_mag - 1 downto 0);
  type index_array is array (0 to n_max - 1) of unsigned(WIDTH_INDICES - 1 downto 0);

  type mag_stage_array is array (0 to STAGES) of mag_array;
  type index_stage_array is array (0 to STAGES) of index_array;

  -- Mask for which lanes belong to the rounded-up power-of-two (n_effective)
  type mask_array is array (0 to n_max - 1) of std_logic;
  signal active_mask : mask_array := (others => '0');

  signal mag_stages : mag_stage_array;
  signal idx_stages : index_stage_array;

  signal stage_valid : std_logic_vector(STAGES downto 0) := (others => '0');
  signal n_r         : integer range 0 to n_max          := 0;
  signal config_done : std_logic                         := '0';
  signal load_en     : std_logic                         := '0';

  signal done_sort_r : std_logic := '0';

begin
  -- output flag when sorting is done
  done_sort <= done_sort_r;

  -- Initialize sorting stages and runtime code length for dynamic n
  process (clk, rst)
    variable n_effective : integer range 0 to n_max; -- n rounded up to power-of-two
  begin
    if rst = '1' then
      n_r <= 0;
      config_done <= '0';
      load_en <= '0';
      active_mask <= (others => '0');

    elsif rising_edge(clk) then
      config_done <= '0';
      load_en <= config_done; -- load enable delayed by one cycle after config
      if sort_en = '1' then -- latch parameters at start of sorting
        n_r <= n;
        n_effective := ceil_pow2(n);

        -- precompute which lanes are active for sorting
        for i in 0 to n_max - 1 loop
          if i < n_effective then
            active_mask(i) <= '1';
          else
            active_mask(i) <= '0';
          end if;
        end loop;

        config_done <= '1';
      end if;
    end if;
  end process;

  -- Stage 0 (load LLR magnitudes,initialize indices)
  process (clk, rst)
  begin
    if (rst = '1') then
      for i in 0 to n_max - 1 loop
        mag_stages(0)(i) <= (others => '0');
        idx_stages(0)(i) <= (others => '0');
      end loop;

    elsif rising_edge(clk) then
      --Take a single flat vector (LLR_mag) that contains all magnitudes concatenated together
      --and splits it into an array of individual unsigned elements(use for compare and swap)
      if load_en = '1' then -- Only load when new data arrives
        for i in 0 to n_max - 1 loop
          if i < n_r then
            mag_stages(0)(i) <= unsigned(LLR_mag((i + 1) * B_mag - 1 downto i * B_mag));
            idx_stages(0)(i) <= to_unsigned(i, WIDTH_INDICES); -- zero-extend the MSBs to match log2(n_max) width and not log2(n)
          elsif active_mask(i) = '1' then -- i < n_effective 
            mag_stages(0)(i) <= (others => '1'); -- pad with max value (11111 = 31)
            idx_stages(0)(i) <= to_unsigned(i, WIDTH_INDICES); -- keep unique index
          else
            mag_stages(0)(i) <= (others => '0');
            idx_stages(0)(i) <= (others => '0');
          end if;
        end loop;
      end if;
    end if;
  end process;

  -- shifting process to enable stages only when inputs are valid
  valid_pipeline: process (clk, rst)
  begin
    if rst = '1' then
      stage_valid <= (others => '0');
      done_sort_r <= '0';

    elsif rising_edge(clk) then
      -- default pulse low
      done_sort_r <= '0';

      -- launch valid token
      stage_valid(0) <= load_en;

      -- shift token
      for s in 1 to STAGES loop
        stage_valid(s) <= stage_valid(s - 1);
      end loop;

      -- done detection (use PRE-shift state)
      if stage_valid(STAGES) = '1' then
        done_sort_r <= '1';
      end if;
    end if;
  end process;

  -- Fully pipelined bitonic network (one (s,k) per stage)
  gen_stages: for s in 0 to LOGN_MAX - 1 generate
    gen_layers: for k in 0 to s generate
      constant stage_idx : integer := s * (s + 1) / 2 + k + 1;
      constant dist      : integer := 2 ** (s - k);
      constant seq_len   : integer := 2 ** (s + 1);
    begin
      process (clk, rst)
        variable tmp_mag      : mag_array;
        variable tmp_idx      : index_array;
        variable partner      : integer;
        variable dir_asc      : boolean;
        variable mag_a, mag_b : unsigned(B_mag - 1 downto 0);
        variable idx_a, idx_b : unsigned(WIDTH_INDICES - 1 downto 0);
      begin
        if rst = '1' then
          for i in 0 to n_max - 1 loop
            mag_stages(stage_idx)(i) <= (others => '0');
            idx_stages(stage_idx)(i) <= (others => '0');
          end loop;

        elsif rising_edge(clk) then
          -- default pass-through (first sorter style)
          for i in 0 to n_max - 1 loop
            tmp_mag(i) := mag_stages(stage_idx - 1)(i);
            tmp_idx(i) := idx_stages(stage_idx - 1)(i);
          end loop;

          if stage_valid(stage_idx - 1) = '1' then

            for i in 0 to n_max - 1 loop

              if active_mask(i) = '1' then

                partner := to_integer(unsigned(to_unsigned(i, WIDTH_INDICES) xor to_unsigned(dist, WIDTH_INDICES)));
                dir_asc := (i mod (2 * seq_len)) < seq_len;

                if (active_mask(partner) = '1') and (unsigned(to_unsigned(i, WIDTH_INDICES) and to_unsigned(dist, WIDTH_INDICES)) = 0) then

                  -- read current working buffers
                  mag_a := tmp_mag(i);
                  mag_b := tmp_mag(partner);
                  idx_a := tmp_idx(i);
                  idx_b := tmp_idx(partner);

                  if dir_asc then -- if ascending
                    if mag_a > mag_b then
                      tmp_mag(i) := mag_b;
                      tmp_mag(partner) := mag_a;
                      tmp_idx(i) := idx_b;
                      tmp_idx(partner) := idx_a;
                    else
                      tmp_mag(i) := mag_a;
                      tmp_mag(partner) := mag_b;
                      tmp_idx(i) := idx_a;
                      tmp_idx(partner) := idx_b;
                    end if;
                  else -- if descending
                    if mag_a < mag_b then
                      tmp_mag(i) := mag_b;
                      tmp_mag(partner) := mag_a;
                      tmp_idx(i) := idx_b;
                      tmp_idx(partner) := idx_a;
                    else
                      tmp_mag(i) := mag_a;
                      tmp_mag(partner) := mag_b;
                      tmp_idx(i) := idx_a;
                      tmp_idx(partner) := idx_b;
                    end if;
                  end if;

                end if;
              end if;
            end loop;
            -- register stage output 
            for i in 0 to n_max - 1 loop
              mag_stages(stage_idx)(i) <= tmp_mag(i);
              idx_stages(stage_idx)(i) <= tmp_idx(i);
            end loop;
          end if;
        end if;
      end process;

    end generate;
  end generate;

  -- Output packing
  process (clk, rst)
  begin
    if rst = '1' then
      sorted_indices <= (others => '0');

    elsif rising_edge(clk) then
      if done_sort_r = '1' then
        for i in 0 to LW_MAX - 1 loop
          sorted_indices((i + 1) * WIDTH_INDICES - 1 downto i * WIDTH_INDICES) <= std_logic_vector(idx_stages(STAGES)(i));
        end loop;
      end if;
    end if;
  end process;

end architecture;
